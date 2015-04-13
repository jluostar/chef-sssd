#
# Cookbook Name:: sssd
# Recipe:: default
#
# Copyright (C) 2015 Localytics
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

if [['realm', 'databag'],['realm', 'databag_item']].any? {|key, subkey| node['sssd'][key][subkey].nil? }
  Chef::Application.fatal!("You must setup the appropriate databags attributes!")
end

if node['sssd']['directory_name'].nil?
  Chef::Application.fatal!("You must set the directory name!")
end

if node['sssd']['computer_name'].nil?
  # If ohai has set the ec2 instance_id, let's use it as the computer_name
  if !node['ec2']['instance_id'].nil?
    computer_name = node['ec2']['instance_id']
  else
    # We must limit the computer name to 15 characters, to avoid truncating:
    #   https://bugs.freedesktop.org/show_bug.cgi?id=69016
    computer_name = node['fqdn'][0..14]
  end
else
  computer_name = node['sssd']['computer_name']
end

# This is created with:
#   openssl rand -base64 512 | tr -d '\r\n' > test/support/encrypted_data_bag_secret
#   knife solo data bag create sssd_credentials realm -c .chef/solo.rb
realm_databag_contents = Chef::EncryptedDataBagItem.load(node['sssd']['realm']['databag'],node['sssd']['realm']['databag_item'])

case node['platform']
when 'ubuntu'
  include_recipe 'apt'
when 'centos'
  include_recipe 'yum'
  include_recipe 'yum-epel'
end

node['sssd']['packages'].each do |pkg|
  package(pkg)
end

# The ideal here (and future PR) is "realm join", but for now, we use adcli due to:
#   CentOS 6: realm is only available in RHEL/CentOS 7
#   Ubuntu 14.04: due to necessary hacky work-arounds to this bug: https://bugs.launchpad.net/ubuntu/+source/realmd/+bug/1333694
bash 'join_domain' do
  user 'root'
  code <<-EOF
  /usr/bin/expect -c 'spawn adcli join --host-fqdn #{computer_name} -U #{realm_databag_contents['username']} #{node['sssd']['directory_name']}
  expect "Password for #{realm_databag_contents['username']}: "
  send "#{realm_databag_contents['password']}\r"
  expect eof'
  EOF
  not_if "klist -k | grep -i '@#{node['sssd']['directory_name']}'"
end

case node['platform']
when 'ubuntu'
  template '/usr/share/pam-configs/my_mkhomedir' do
    source 'my_mkhomedir.erb'
    owner 'root'
    group 'root'
    mode '0644'
    notifies :run, "execute[pam-auth-update]"
  end

  # Enable automatic home directory creation
  execute 'pam-auth-update' do
    command 'pam-auth-update --package'
    action :nothing
  end
when 'centos'
  bash 'enable_sssd' do
    user 'root'
    code <<-EOF
    authconfig --enablemkhomedir --enablesssd --enablesssdauth --update
    echo 'sudoers:    files sss' >> /etc/nsswitch.conf
    EOF
    not_if "grep -i 'sudoers:    files sss' /etc/nsswitch.conf"
  end
end

template '/etc/sssd/sssd.conf' do
  source 'sssd.conf.erb'
  owner 'root'
  group 'root'
  mode '0600'
  notifies :restart, 'service[sssd]', :immediately
  variables({
    :domain => node['sssd']['directory_name'],
    :realm => node['sssd']['directory_name'].upcase,
    :ldap_base => node['sssd']['directory_name'].split('.').map { |s| "dc=#{s}" }.join(','),
    :sasl_authid => computer_name.upcase
  })
end

service 'sssd' do
  supports :status => true, :restart => true, :reload => true
  action [:enable]
end
