GITHASH := $(shell sh -c 'git rev-parse --short HEAD')
default: uploads3dev

uploads3dev:
	mkdir -p bin
	git archive -o bin/ansible-aws-squid-$(GITHASH).zip HEAD
	aws s3 cp bin/ansible-aws-squid-$(GITHASH).zip s3://sb-dev-rpm/ansible-aws-squid-$(GITHASH).zip

.PHONY: bundle templates
