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
BOOTSTRAP_SECRETS = ENV["INVESTHELPER_SECRETS_FILE"]
VAULT_PASSWORD_FILE = ENV["INVESTHELPER_VAULT_PASSWORD_FILE"]
[BOOTSTRAP_SECRETS, VAULT_PASSWORD_FILE].compact.each do |path|
  raise "Bootstrap input file does not exist: #{path}" unless File.file?(path)
end

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
  # Windows Hyper-V/NEM can make guest boot exceed the default 300 seconds.
  # This tolerates slow boots; it does not resolve host hypervisor contention.
  config.vm.boot_timeout = 600

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

        # Configure DNS before the first apt invocation, not only later in Ansible.
        printf '%s\n' \
          'network:' '  version: 2' '  ethernets:' '    enp0s3:' \
          '      dhcp4: true' '      dhcp4-overrides:' '        use-dns: false' \
          '      dhcp6-overrides:' '        use-dns: false' \
          '      nameservers:' '        addresses: [10.0.2.3]' \
          > /etc/netplan/99-investhelper-dns.yaml
        chmod 0600 /etc/netplan/99-investhelper-dns.yaml
        netplan apply

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
        if BOOTSTRAP_SECRETS
          machine.vm.provision "shell", privileged: true, inline: <<-SHELL
            install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.config/investhelper
          SHELL
          machine.vm.provision "file", source: BOOTSTRAP_SECRETS,
            destination: "/home/vagrant/.config/investhelper/bootstrap.yml"
          if VAULT_PASSWORD_FILE
            machine.vm.provision "file", source: VAULT_PASSWORD_FILE,
              destination: "/home/vagrant/.config/investhelper/vault-password"
          end
        end
        machine.vm.provision "file",
          source: ANSIBLE_PRIVATE_KEY,
          destination: "/tmp/ansible_control_ed25519"
        machine.vm.provision "file",
          source: "ansible",
          destination: "/tmp/ansible"

        machine.vm.provision "shell", privileged: true, inline: <<-SHELL
          set -eu

          trap 'rm -f /home/vagrant/.config/investhelper/vault-password' EXIT
          DEBIAN_FRONTEND=noninteractive apt-get install -y ansible

          install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.ssh
          install -m 0600 -o vagrant -g vagrant \
            /tmp/ansible_control_ed25519 \
            /home/vagrant/.ssh/ansible_control_ed25519
          rm -f /tmp/ansible_control_ed25519

          # Preserve locally added encrypted group_vars on repeated provisioning.
          install -d /opt/investhelper-ansible
          cp -a /tmp/ansible/. /opt/investhelper-ansible/
          rm -rf /tmp/ansible
          chown -R vagrant:vagrant /opt/investhelper-ansible
          if [ "#{BOOTSTRAP_SECRETS ? 'yes' : 'no'}" = yes ]; then
            secret_dir=/home/vagrant/.config/investhelper
            chmod 0600 "$secret_dir/bootstrap.yml"
            # The decryption password is needed only for this provisioning run.
            if [ "#{VAULT_PASSWORD_FILE ? 'yes' : 'no'}" = yes ]; then
              chmod 0600 "$secret_dir/vault-password"
              sudo -u vagrant bash -lc \
                'cd /opt/investhelper-ansible && ansible-playbook playbooks/bootstrap.yml --extra-vars @/home/vagrant/.config/investhelper/bootstrap.yml --vault-password-file /home/vagrant/.config/investhelper/vault-password'
            else
              sudo -u vagrant bash -lc \
                'cd /opt/investhelper-ansible && ansible-playbook playbooks/bootstrap.yml --extra-vars @/home/vagrant/.config/investhelper/bootstrap.yml'
            fi
          else
            sudo -u vagrant bash -lc \
              'cd /opt/investhelper-ansible && ansible-playbook playbooks/site.yml'
          fi
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
