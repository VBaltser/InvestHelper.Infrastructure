# frozen_string_literal: true

require "fileutils"
require "base64"
require "shellwords"

VAGRANTFILE_API_VERSION = "2"

# Managed nodes come first so they are reachable when control runs Ansible.
VM_CONFIG = {
  "ci" => { ip: "192.168.56.10", cpus: 2, memory: 4096, role: :managed },
  "app" => { ip: "192.168.56.20", cpus: 2, memory: 3072, role: :managed },
  "monitoring" => { ip: "192.168.56.30", cpus: 2, memory: 3072, role: :managed },
  "control" => { ip: "192.168.56.5", cpus: 1, memory: 1024, role: :control }
}.freeze

VAGRANT_STATE_DIR = File.expand_path(".vagrant", __dir__)
ANSIBLE_PRIVATE_KEY = File.join(VAGRANT_STATE_DIR, "ansible_control_ed25519")
ANSIBLE_PUBLIC_KEY = "#{ANSIBLE_PRIVATE_KEY}.pub"

unless File.exist?(ANSIBLE_PRIVATE_KEY) && File.exist?(ANSIBLE_PUBLIC_KEY)
  FileUtils.mkdir_p(VAGRANT_STATE_DIR)
  generated = system(
    "ssh-keygen",
    "-q",
    "-t", "ed25519",
    "-N", "",
    "-C", "investhelper-ansible-control",
    "-f", ANSIBLE_PRIVATE_KEY
  )
  raise "Cannot create the Ansible SSH key. Install OpenSSH client and retry." unless generated
end

control_public_key = File.read(ANSIBLE_PUBLIC_KEY).strip
escaped_control_public_key = Shellwords.escape(control_public_key)

hosts_entries = VM_CONFIG.map do |name, vm|
  "#{vm[:ip]} #{name}"
end.join("\n")
hosts_entries_base64 = Base64.strict_encode64("#{hosts_entries}\n")

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.box_check_update = false

  # Configuration is delivered over SSH, so the machines do not need the
  # VirtualBox shared-folder plugin or Guest Additions.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  VM_CONFIG.each do |name, vm|
    config.vm.define name do |machine|
      machine.vm.hostname = name
      machine.vm.network "private_network", ip: vm[:ip]

      machine.vm.provider "virtualbox" do |virtualbox|
        virtualbox.name = "investhelper-#{name}"
        virtualbox.gui = false
        virtualbox.cpus = vm[:cpus]
        virtualbox.memory = vm[:memory]
        # Let VirtualBox resolve guest DNS queries through the host. This is
        # more reliable on Windows hosts with VPNs or corporate DNS.
        virtualbox.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
        virtualbox.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
      end

      machine.vm.provision "shell", privileged: true, inline: <<-SHELL
        set -eu

        echo #{hosts_entries_base64} | base64 --decode > /tmp/investhelper-hosts

        while IFS= read -r host_entry; do
          grep -qF "$host_entry" /etc/hosts || echo "$host_entry" >> /etc/hosts
        done < /tmp/investhelper-hosts
        rm -f /tmp/investhelper-hosts

        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
          ca-certificates \
          curl \
          python3 \
          python3-apt

        # Ansible uses this directory after privilege escalation. Creating it
        # explicitly avoids the remote_tmp permissions warning.
        install -d -m 0700 /root/.ansible/tmp
      SHELL

      if vm[:role] == :control
        machine.vm.provision "file",
          source: ANSIBLE_PRIVATE_KEY,
          destination: "/tmp/ansible_control_ed25519"
        machine.vm.provision "file",
          source: "ansible",
          destination: "/tmp/ansible"

        machine.vm.provision "shell", privileged: true, inline: <<-SHELL
          set -eu

          DEBIAN_FRONTEND=noninteractive apt-get install -y ansible

          install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.ssh
          install -m 0600 -o vagrant -g vagrant \
            /tmp/ansible_control_ed25519 \
            /home/vagrant/.ssh/ansible_control_ed25519
          rm -f /tmp/ansible_control_ed25519

          rm -rf /opt/investhelper-ansible
          mv /tmp/ansible /opt/investhelper-ansible
          chown -R vagrant:vagrant /opt/investhelper-ansible
          sudo -u vagrant bash -lc \
            'cd /opt/investhelper-ansible && ansible-playbook playbooks/site.yml'
        SHELL
      else
        machine.vm.provision "shell", privileged: true, inline: <<-SHELL
          set -eu

          install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.ssh
          touch /home/vagrant/.ssh/authorized_keys
          chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
          chmod 0600 /home/vagrant/.ssh/authorized_keys

          control_key=#{escaped_control_public_key}
          grep -qF "$control_key" /home/vagrant/.ssh/authorized_keys || \
            echo "$control_key" >> /home/vagrant/.ssh/authorized_keys
        SHELL
      end
    end
  end
end
