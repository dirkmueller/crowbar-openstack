#
# Copyright 2011-2013, Dell
# Copyright 2013-2014, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class DatabaseService < PacemakerServiceObject
  def initialize(thelogger = nil)
    super(thelogger)
    @bc_name = "database"
  end

# turn off nulti proposal support till it really works and people ask for it.
  def self.allow_multiple_proposals?
    false
  end

  class << self
    def role_constraints
      {
        "database-server" => {
          "unique" => false,
          "count" => 1,
          "cluster" => true,
          "admin" => false,
          "exclude_platform" => {
            "suse" => "< 12.2",
            "windows" => "/.*/"
          }
        },
        "mysql-server" => {
          "unique" => false,
          "count" => 1,
          "cluster" => true,
          "admin" => false,
          "exclude_platform" => {
            "suse" => "< 12.2",
            "windows" => "/.*/"
          }
        }
      }
    end
  end

  def create_proposal
    @logger.debug("Database create_proposal: entering")
    base = super

    db_role = if base["attributes"]["sql_engine"] == "postgresql"
      "database-server"
    else
      "mysql-server"
    end

    nodes = NodeObject.all
    nodes.delete_if { |n| n.nil? or n.admin? }
    if nodes.size >= 1
      controller = nodes.find { |n| n.intended_role == "controller" } || nodes.first
      base["deployment"]["database"]["elements"] = {
        db_role => [controller[:fqdn]]
      }
    end

    @logger.debug("Database create_proposal: exiting")
    base
  end

  def validate_ha_attributes(attributes, cluster)
    role = available_clusters[cluster]

    case attributes["sql_engine"]
    when "postgresql"
      ha_attr = attributes["postgresql"]["ha"]
      storage_mode = ha_attr["storage"]["mode"]
      unless ["shared", "drbd"].include?(storage_mode)
        validation_error I18n.t(
          "barclamp.#{@bc_name}.validation.unknown_mode_ha",
          storage_mode: storage_mode
        )
      end
      if storage_mode == "shared"
        if ha_attr["storage"]["shared"]["device"].blank?
          validation_error I18n.t(
            "barclamp.#{@bc_name}.validation.no_device"
          )
        end
        if ha_attr["storage"]["shared"]["fstype"].blank?
          validation_error I18n.t(
            "barclamp.#{@bc_name}.validation.no_filesystem"
          )
        end
      elsif storage_mode == "drbd"
        unless role.default_attributes["pacemaker"]["drbd"]["enabled"]
          validation_error I18n.t(
            "barclamp.#{@bc_name}.validation.drbd_not_enabled",
            cluster_name: cluster_name(cluster)
          )
        end
        if ha_attr["storage"]["drbd"]["size"] <= 0
          validation_error I18n.t(
            "barclamp.#{@bc_name}.validation.invalid_size_drbd"
          )
        end
      end
    when "mysql"
      nodes = PacemakerServiceObject.expand_nodes(cluster) || []
      if nodes.size == 1
        validation_error I18n.t(
          "barclamp.#{@bc_name}.validation.cluster_size_one"
        )
      elsif nodes.size.even?
        validation_error I18n.t(
          "barclamp.#{@bc_name}.validation.cluster_size_even"
        )
      end
    end
  end

  def validate_proposal_after_save(proposal)
    attributes = proposal["attributes"][@bc_name]
    sql_engine = attributes["sql_engine"]
    db_role = if sql_engine == "postgresql"
      "database-server"
    else
      "mysql-server"
    end
    validate_one_for_role proposal, db_role

    validation_error I18n.t(
      "barclamp.#{@bc_name}.validation.invalid_db_engine",
      db_engine: sql_engine
    ) unless ["mysql", "postgresql"].include?(sql_engine)

    # HA validation
    servers = proposal["deployment"][@bc_name]["elements"][db_role]
    unless servers.nil? || servers.first.nil? || !is_cluster?(servers.first)
      cluster = servers.first
      validate_ha_attributes(attributes, cluster)
    end

    super
  end

  def apply_role_pre_chef_call(old_role, role, all_nodes)
    @logger.debug("Database apply_role_pre_chef_call: entering #{all_nodes.inspect}")
    return if all_nodes.empty?

    sql_engine = role.default_attributes["database"]["sql_engine"]

    vip_networks = ["admin"]
    dirty = false
    net_svc = NetworkService.new @logger
    db_enabled = {
      "mysql" => {
        "enabled" => false,
        "ha" => false
      },
      "postgresql" => {
        "enabled" => false,
        "ha" => false
      }
    }
    ["postgresql", "mysql"].each do |engine|
      db_role = if engine == "postgresql"
        "database-server"
      else
        "mysql-server"
      end
      database_elements, database_nodes, database_ha_enabled = role_expand_elements(role, db_role)
      db_enabled[engine]["enabled"] = true unless database_nodes.empty?
      db_enabled[engine]["ha"] = database_ha_enabled
      Openstack::HA.set_controller_role(database_nodes) if database_ha_enabled
      dirty = prepare_role_for_ha_with_haproxy(role,
                                               ["database", engine, "ha", "enabled"],
                                               database_ha_enabled,
                                               database_elements,
                                               vip_networks) || dirty
      reset_sync_marks_on_clusters_founders(database_elements)
      next unless database_ha_enabled
      case engine
      when "postgresql"
        unless database_elements.length == 1 && PacemakerServiceObject.is_cluster?(database_elements[0])
          raise "Internal error: HA enabled, but element is not a cluster"
        end
        cluster = database_elements[0]
        cluster_name = PacemakerServiceObject.cluster_name(cluster)
        # Any change in the generation of the vhostname here must be reflected in
        # CrowbarDatabaseHelper.get_ha_vhostname
        database_vhostname = "#{role.name.gsub("-config", "")}-#{cluster_name}.#{Crowbar::Settings.domain}".tr("_", "-")
        net_svc.allocate_virtual_ip "default", "admin", "host", database_vhostname
      when "mysql"
        database_nodes.each do |n|
          net_svc.allocate_ip "default", "admin", "host", n
        end
        allocate_virtual_ips_for_any_cluster_in_networks(database_elements, vip_networks)
      end
    end
    role.save if dirty

    role.default_attributes["database"][sql_engine] = {} if role.default_attributes["database"][sql_engine].nil?
    role.default_attributes["database"]["db_maker_password"] = (old_role && old_role.default_attributes["database"]["db_maker_password"]) || random_password

    if db_enabled["mysql"]["enabled"]
      role.default_attributes["database"]["mysql"]["server_root_password"] = (old_role && old_role.default_attributes["database"]["mysql"]["server_root_password"]) || random_password
      if db_enabled["mysql"]["ha"]
        role.default_attributes["database"]["mysql"]["sstuser_password"] = (old_role && old_role.default_attributes["database"]["mysql"]["sstuser_password"]) || random_password
      end
      @logger.debug("setting mysql specific attributes")
    end
    if db_enabled["postgresql"]["enabled"]
      # Attribute is not living in "database" namespace, but that's because
      # it's for the postgresql cookbook. We're not using default_attributes
      # because the upstream cookbook use node.set_unless which would override
      # a default attribute.
      role.override_attributes["postgresql"] ||= {}
      role.override_attributes["postgresql"]["password"] ||= {}
      role.override_attributes["postgresql"]["password"]["postgres"] = (old_role && (old_role.override_attributes["postgresql"]["password"]["postgres"] rescue nil)) || random_password
      @logger.debug("setting postgresql specific attributes")
    end

    # Copy the attributes for database/<sql_engine> to <sql_engine> in the
    # role attributes to avoid renaming all attributes everywhere in the
    # postgres and mysql cookbooks
    # (FIXME: is there a better way to achieve this?)
    role.default_attributes[sql_engine] = role.default_attributes["database"][sql_engine]
    role.save

    @logger.debug("Database apply_role_pre_chef_call: leaving")
  end

  def post_schema_migration_callback(proposal, role)
    return if role.nil?
    sql_engine = role.default_attributes["database"]["sql_engine"]
    role.default_attributes[sql_engine] = role.default_attributes["database"][sql_engine]
    role.save
  end
end
