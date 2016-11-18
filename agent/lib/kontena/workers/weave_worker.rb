require 'docker'
require_relative '../logging'
require_relative '../helpers/weave_helper'

module Kontena::Workers
  class WeaveWorker
    include Celluloid
    include Celluloid::Notifications
    include Kontena::Logging
    include Kontena::Helpers::WeaveHelper

    def initialize
      info 'initialized'
      subscribe('network_adapter:start', :on_weave_start)
      subscribe('container:event', :on_container_event)
      subscribe('dns:add', :on_dns_add)
    end

    def on_weave_start(topic, data)
      self.start
    end

    def start
      wait_weave_running?
      info 'attaching network to existing containers'
      Docker::Container.all(all: false).each do |container|
        self.weave_attach(container)
      end
    end

    def on_dns_add(topic, event)
      wait_weave_running?
      add_dns(event[:id], event[:ip], event[:name])
    end

    # @param [String] topic
    # @param [Docker::Event] event
    def on_container_event(topic, event)
      if event.status == 'start'
        wait_weave_running?
        container = Docker::Container.get(event.id) rescue nil
        if container
          self.weave_attach(container)
        end
      elsif event.status == 'restart'
        if network_adapter.router_image?(event.from)
          self.start
        end

      elsif event.status == 'destroy'
        network_adapter.detach_network(event)
      end
    end

    # @param [Docker::Container] container
    def weave_attach(container)
      overlay_cidr = container.overlay_cidr
      if overlay_cidr
        register_container_dns(container)
        attach_overlay(container.id, overlay_cidr)
      else
        debug "did not find ip for container: #{container.name}, not attaching to weave"
      end
    rescue Docker::Error::NotFoundError

    rescue => exc
      error "#{exc.class.name}: #{exc.message}"
      error exc.backtrace.join("\n")
    end

    # @param [String] container_id
    # @param [String] overlay_cidr
    def attach_overlay(container_id, overlay_cidr)
      network_adapter.exec(['--local', 'attach', overlay_cidr, '--rewrite-hosts', container_id])
    end

    # @param [Docker::Container]
    def register_container_dns(container)
      grid_name = container.labels['io.kontena.grid.name']
      service_name = container.labels['io.kontena.service.name']
      instance_number = container.labels['io.kontena.service.instance_number']
      domain_name = container.config['Domainname'] || "#{grid_name}.kontena.local"
      if container.default_stack?
        hostname = container.labels['io.kontena.container.name']
        dns_names = default_stack_dns_names(hostname, service_name, domain_name)
        dns_names = dns_names + stack_dns_names(hostname, service_name, domain_name)

      else
        hostname = container.config['Hostname']
        dns_names = stack_dns_names(hostname, service_name, domain_name)
      end
      dns_names.each do |name|
        add_dns(container.id, container.overlay_ip, name)
      end
    end

    # @param [String] hostname
    # @param [String] service_name
    # @param [String] domain_name
    def default_stack_dns_names(hostname, service_name, domain_name)
      base_domain = domain_name.split('.', 2)[1]
      [
        "#{hostname}.#{base_domain}",
        "#{service_name}.#{base_domain}"
      ]
    end

    # @param [String] hostname
    # @param [String] service_name
    # @param [String] domain_name
    def stack_dns_names(hostname, service_name, domain_name)
      dns_names = [
        "#{service_name}.#{domain_name}",
        "#{hostname}.#{domain_name}"
      ]
    end
  end
end
