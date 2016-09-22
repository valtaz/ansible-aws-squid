ansible-aws-squid
=========

ansible role which setup a transparent proxy server on aws base on https://blogs.aws.amazon.com/security/post/TxFRX7UFUIT2GD/How-to-Add-DNS-Filtering-to-Your-NAT-Instance-with-Squid

Requirements
------------

- awscli
- squid rpm package in s3

Role Variables
--------------

aws_region: ap-southeast-2
install_s3_bucket_name: varutatthakornpun
squid_package: squid-3.5.20-1.el6.x86_64.rpm

Dependencies
------------

A list of other roles hosted on Galaxy should go here, plus any details in regards to parameters that may need to be set for other roles, or variables that are used from other roles.

Example Playbook
----------------

Including an example of how to use your role (for instance, with variables passed in as parameters) is always nice for users too:

    - hosts: servers
      roles:
         - { role: username.rolename, x: 42 }

License
-------

BSD

Author Information
------------------

An optional section for the role authors to include contact information, or a website (HTML is not allowed).
