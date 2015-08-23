module Pec::Handler
  class Networks < Base 
    self.kind = 'networks'
    autoload :OptionBase,          "pec/handler/networks/option_base"
    autoload :IpAddress,           "pec/handler/networks/ip_address"
    autoload :AllowedAddressPairs, "pec/handler/networks/allowed_address_pairs"
    
    class << self
      NAME = 0
      CONFIG = 1

      def build(host)
        ports = []
        user_data = []

        host.networks.each do |network|
          validate(network)
          Pec::Logger.notice "port create start : #{network[NAME]}"
          port = create_port(host, network)
          Pec::Logger.notice "assgin ip : #{port.fixed_ips.first["ip_address"]}"
          ports << port
          user_data << gen_user_data(network, port)
        end
        {
          nics: ports.map {|port| { port_id: port.id }},
          user_data: {
            'write_files' => user_data
          }
        }
      end

      def validate(network)
        %w(
          bootproto
          ip_address
        ).each do |k|
          raise "network key #{k} is require" unless network[CONFIG][k]
        end
      end

      def create_port(host, network)
        attribute = gen_port_attribute(host, network)
        Pec.neutron.ports.create(attribute)
      end
     
      def gen_port_attribute(host, network)
        ip = IP.new(network[CONFIG]['ip_address'])
        subnet = Pec.neutron.subnets.find {|s|s.cidr == ip.network.to_s}
        attribute = {
          name: network[NAME],
          network_id: subnet.network_id
        }
        
        attribute.merge!(
          security_group(host)
        ) if host.security_group

        network[CONFIG].keys.each do |k|
          Pec::Handler::Networks.constants.each do |c|
            if Object.const_get("Pec::Handler::Networks::#{c}").kind == k &&
                ops = Object.const_get("Pec::Handler::Networks::#{c}").build(network)
              attribute.deep_merge!(ops)
            end
          end
        end

        attribute
      end
     
      def gen_user_data(network, port)
        path = network[CONFIG]['path'] || "/etc/sysconfig/network-scripts/ifcfg-#{port.name}"
        {
          'content' => ifcfg_config(network, port),
          'owner' => "root:root",
          'path' => path,
          'permissions' => "0644"
        }
      end
      
      def ifcfg_config(network, port)
        base = {
          "name"      => port.name,
          "device"    => port.name,
          "type"      => 'Ethernet',
          "onboot"    => 'yes',
          "hwaddr"    => port.mac_address
        }
        
        base.merge!(
          {
            "netmask" => IP.new(network[CONFIG]['ip_address']).netmask.to_s,
            "ipaddr"  => port.fixed_ips.first['ip_address'].split("/").first
          }
        ) if network[CONFIG]['bootproto'] == "static"

        # delete option column
        Pec::Handler::Networks.constants.each do |c|
          network[CONFIG].delete(Object.const_get("Pec::Handler::Networks::#{c}").kind)
        end 

        base.merge!(
          network[CONFIG]
        )
        base.map {|k,v| "#{k.upcase}=#{v}"}.join("\n")
      end

      def security_group(host)
        ids = host.security_group.map do |name|
          Pec.neutron.security_groups.find {|sg| sg.name == name}.id
        end
        { security_groups: ids }
      end
    end
  end
end