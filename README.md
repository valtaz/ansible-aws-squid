ansible-aws-squid
=========

ansible role which setup a transparent proxy server on aws base on https://blogs.aws.amazon.com/security/post/TxFRX7UFUIT2GD/How-to-Add-DNS-Filtering-to-Your-NAT-Instance-with-Squid

Requirements
------------

- awscli
- squid rpm package in s3
- IAM role which allow to access S3

Role Variables
--------------

aws_region: ap-southeast-2
install_s3_bucket_name: sb-dev-rpm
squid_package: squid-3.5.20-1.el6.x86_64.rpm

Dependencies
------------

- None


Example Playbook
----------------

Including an example of how to use your role (for instance, with variables passed in as parameters) is always nice for users too:

    - hosts: servers
      roles:
         - { role: ansible-aws-squid,  
                  aws_region: "ap-southeast-2",
                  install_s3_bucket_name: "sb-dev-rpm",
                  squid_package: "squid-3.5.20-1.el7.centos.x86_64.rpm"
           }
