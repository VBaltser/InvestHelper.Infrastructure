# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "base64"

VAGRANTFILE_API_VERSION = "2"

VM_CONFIG = {
  "control" => {
    hostname: "control",
    ip: "192.168.56.5",
    cpus: 2,
    memory: 2048,
    role: :control
  },
  "jenkins" => {
    hostname: "jenkins",
    ip: "192.168.56.10",
    cpus: 2,
    memory: 4096,
    role: :managed
  },
  "app" => {
    hostname: "app",
    ip: "192.168.56.20",
    cpus: 2,
    memory: 4096,
    role: :managed
  }
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

hosts_entries = VM_CONFIG.map do |_name, vm|
  "#{vm[:ip]} #{vm[:hostname]}"
end.join("\n")
hosts_entries_base64 = Base64.strict_encode64("#{hosts_entries}\n")

ansible_inventory = <<~INVENTORY
  [jenkins]
  jenkins ansible_host=192.168.56.10

  [app]
  app ansible_host=192.168.56.20

  [managed:children]
  jenkins
  app

  [managed:vars]
  ansible_user=vagrant
  ansible_ssh_private_key_file=/home/vagrant/.ssh/ansible_control_ed25519
  ansible_python_interpreter=/usr/bin/python3
  ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'
INVENTORY
ansible_inventory_base64 = Base64.strict_encode64(ansible_inventory)

ansible_config = <<~CONFIG
  [defaults]
  inventory = inventory.ini
  interpreter_python = auto_silent
  retry_files_enabled = False
CONFIG
ansible_config_base64 = Base64.strict_encode64(ansible_config)

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.box_check_update = true

  # Configuration is delivered over SSH, so the machines do not need the
  # VirtualBox shared-folder plugin or Guest Additions.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  VM_CONFIG.each do |name, vm|
    config.vm.define name do |machine|
      machine.vm.hostname = vm[:hostname]
      machine.vm.network "private_network", ip: vm[:ip]

      machine.vm.provider "virtualbox" do |virtualbox|
        virtualbox.name = "investhelper-#{name}"
        virtualbox.gui = false
        virtualbox.cpus = vm[:cpus]
        virtualbox.memory = vm[:memory]
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
      SHELL

      if vm[:role] == :control
        machine.vm.provision "file",
          source: ANSIBLE_PRIVATE_KEY,
          destination: "/tmp/ansible_control_ed25519"

        machine.vm.provision "shell", privileged: true, inline: <<-SHELL
          set -eu

          DEBIAN_FRONTEND=noninteractive apt-get install -y ansible

          install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.ssh
          install -m 0600 -o vagrant -g vagrant \
            /tmp/ansible_control_ed25519 \
            /home/vagrant/.ssh/ansible_control_ed25519
          rm -f /tmp/ansible_control_ed25519

          install -d -m 0755 -o vagrant -g vagrant /home/vagrant/ansible
          echo #{ansible_inventory_base64} | base64 --decode > \
            /home/vagrant/ansible/inventory.ini
          echo #{ansible_config_base64} | base64 --decode > \
            /home/vagrant/ansible/ansible.cfg

          chown -R vagrant:vagrant /home/vagrant/ansible
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
