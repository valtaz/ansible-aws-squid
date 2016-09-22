from testinfra.utils.ansible_runner import AnsibleRunner
import pytest
import requests

testinfra_hosts = AnsibleRunner('.molecule/ansible_inventory').get_hosts('all')


# def test_squid_running_and_enabled(Service, SystemInfo):
#     squid = Service("squid")
#     assert squid.is_enabled
#     if SystemInfo.distribution == 'centos':
#         assert squid.is_running
# 
# def test_squid_dot_conf(File):
#     squid = File("/etc/squid/squid.conf")
#     assert squid.user == "root"
#     assert squid.group == "root"
#     assert squid.mode == 0o644
#     assert squid.contains('acl allowed_https_sites ssl::server_name .amazonaws.com')

def test_squid_package(Package, SystemInfo):
    squid = Package('squid')
    assert squid.is_installed
