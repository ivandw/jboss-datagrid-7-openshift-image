DEV_IMAGE_ORG = jboss-datagrid-7
DEV_IMAGE_NAME = datagrid73-openshift
DEV_IMAGE_TAG = latest
DOCKER_REGISTRY_ENGINEERING =
DOCKER_REGISTRY_REDHAT =
ADDITIONAL_ARGUMENTS =

CE_DOCKER = $(shell docker version | grep Version | head -n 1 | grep -e "-ce")
ifneq ($(CE_DOCKER),)
DOCKER_REGISTRY_ENGINEERING = docker-registry.engineering.redhat.com
DOCKER_REGISTRY_REDHAT = registry.redhat.io/
DEV_IMAGE_FULL_NAME = $(DOCKER_REGISTRY_ENGINEERING)/$(DEV_IMAGE_ORG)/$(DEV_IMAGE_NAME):$(DEV_IMAGE_TAG)
IMAGE_FULL_NAME = $(DOCKER_REGISTRY_ENGINEERING)/$(DEV_IMAGE_ORG)/$(IMAGE_NAME):$(DEV_IMAGE_TAG)
CEKIT_CMD = cekit --overrides-file=overrides.yaml --target target-docker build docker
else
DEV_IMAGE_FULL_NAME = $(DEV_IMAGE_ORG)/$(DEV_IMAGE_NAME):$(DEV_IMAGE_TAG)
CEKIT_CMD = cekit --target target-docker build docker
endif

DOCKER_MEMORY=512M
MVN_COMMAND = mvn -s services/functional-tests/maven-settings.xml
_TEST_PROJECT = myproject

#Set variables for remote openshift when OPENSHIFT_ONLINE_REGISTRY is defined
ifeq ($(OPENSHIFT_ONLINE_REGISTRY),)
_OPENSHIFT_MASTER = https://127.0.0.1:8443
_DOCKER_REGISTRY = $(shell oc get svc/docker-registry -n default -o yaml | grep 'clusterIP:' | awk '{print $$2":5000"}')
_IMAGE = $(_DOCKER_REGISTRY)/$(_TEST_PROJECT)/$(DEV_IMAGE_NAME):$(DEV_IMAGE_TAG)
_OPENSHIFT_USERNAME = developer
_OPENSHIFT_PASSWORD = developer
_TESTRUNNER_PORT = 80
_DEV_IMAGE_STREAM = $(_DOCKER_REGISTRY)/$(_TEST_PROJECT)/$(DEV_IMAGE_NAME):$(DEV_IMAGE_TAG)
else
_DOCKER_REGISTRY = $(OPENSHIFT_ONLINE_REGISTRY)
_IMAGE = $(_DOCKER_REGISTRY)/$(_TEST_PROJECT)/$(DEV_IMAGE_NAME):$(DEV_IMAGE_TAG)
_TESTRUNNER_PORT = 80
_DEV_IMAGE_STREAM = $(DEV_IMAGE_NAME):$(DEV_IMAGE_TAG)
endif

# This username and password is hardcoded (and base64 encoded) in the Ansible
# Service Broker template
_ANSIBLE_SERVICE_BROKER_USERNAME = admin
_ANSIBLE_SERVICE_BROKER_PASSWORD = admin

OPENSHIFT_PUBLIC_HOSTNAME?=127.0.0.1

start-openshift-with-catalog:
	@echo "---- Starting OpenShift ----"
	oc cluster up --public-hostname=$(OPENSHIFT_PUBLIC_HOSTNAME)
	oc cluster add service-catalog
	@echo "---- Granting admin rights to Developer ----"
	oc login -u system:admin
	oc adm policy add-cluster-role-to-user cluster-admin $(_OPENSHIFT_USERNAME)

	@echo "---- Allowing containers to run specific users ----"
	# Some of the JDK commands (jcmd, jps etc.) require the same user as the one running java process.
	# The command below enabled that. The process inside the container will be ran using jboss user.
	# The same users will be used by default for `oc rsh` command.
	oc adm policy add-scc-to-group anyuid system:authenticated
.PHONY: start-openshift-with-catalog

prepare-openshift-project: clean-openshift
	@echo "---- Create main project for test purposes"
	oc new-project $(_TEST_PROJECT)

	@echo "---- Switching to test project ----"
	oc project $(_TEST_PROJECT)
.PHONY: prepare-openshift-project

clean-openshift:
	@echo "---- Deleting projects ----"
	oc delete project $(_TEST_PROJECT) || true
	( \
		while oc get projects | grep -e $(_TEST_PROJECT) > /dev/null; do \
			echo "Waiting for deleted projects..."; \
			sleep 5; \
		done; \
	)
.PHONY: clean-openshift

login-to-openshift:
	@echo "---- Login ----"
	oc login $(_OPENSHIFT_MASTER) -u $(_OPENSHIFT_USERNAME) -p $(_OPENSHIFT_PASSWORD)
.PHONY: login-to-openshift

start-openshift-with-catalog-and-ansible-service-broker: start-openshift-with-catalog login-to-openshift prepare-openshift-project install-ansible-service-broker
.PHONY: start-openshift-with-catalog-and-ansible-service-broker

install-ansible-service-broker:
	@echo "---- Installing Ansible Service Broker ----"
	oc new-project ansible-service-broker
	( \
		curl -s https://raw.githubusercontent.com/openshift/ansible-service-broker/master/templates/deploy-ansible-service-broker.template.yaml \
        | oc process \
        -n ansible-service-broker \
        -p BROKER_KIND="Broker" \
        -p BROKER_AUTH="{\"basicAuthSecret\":{\"namespace\":\"ansible-service-broker\",\"name\":\"asb-auth-secret\"}}" \
        -p ENABLE_BASIC_AUTH="true" -f - | oc create -f - \
	)
.PHONY: install-ansible-service-broker

stop-openshift:
	oc cluster down || true
	# Hack to remove leftover mounts https://github.com/openshift/origin/issues/19141
	for i in $(shell mount | grep openshift | awk '{ print $$3}'); do sudo umount "$$i"; done
	sudo rm -rf ./openshift.local.clusterup

	# Remove leftover containers
	sudo rm -rf /var/lib/origin
.PHONY: stop-openshift

build-image:
	$(CEKIT_CMD)
.PHONY: build-image

_login_to_docker:
	sudo docker login -u $(shell oc whoami) -p $(shell oc whoami -t) $(_DOCKER_REGISTRY)
.PHONY: _login_to_docker

_wait_for_local_docker_registry:
	( \
      for i in `seq 1 20`; do \
         if ! oc get pod -n default | grep docker-registry | grep "1/1" > /dev/null; then \
            echo "Waiting for Docker Registry..."; \
            sleep 10; \
         fi; \
      done; \
	)
.PHONY: _wait_for_local_docker_registry

_add_openshift_push_permissions:
	oc adm policy add-role-to-user system:registry $(_OPENSHIFT_USERNAME)
	oc adm policy add-role-to-user admin $(_OPENSHIFT_USERNAME) -n $(_TEST_PROJECT)
	oc adm policy add-role-to-user system:image-builder $(_OPENSHIFT_USERNAME)
.PHONY: _add_openshift_push_permissions

push-image-to-local-openshift: _add_openshift_push_permissions _wait_for_local_docker_registry _login_to_docker push-image-common
.PHONY: push-image-to-local-openshift

push-image-to-online-openshift: _login_to_docker push-image-common
.PHONY: push-image-to-online-openshift

pull-image:
	docker pull $(DEV_IMAGE_FULL_NAME)
.PHONY: pull-image

push-image-common:
	sudo docker tag $(DEV_IMAGE_FULL_NAME) $(_IMAGE)
	sudo docker push $(_IMAGE)
	oc set image-lookup $(DEV_IMAGE_NAME)
.PHONY: push-image-common

test-functional: deploy-testrunner-route
	$(MVN_COMMAND) -Dimage=$(_DEV_IMAGE_STREAM) -Dkubernetes.auth.token=$(shell oc whoami -t) -DDOCKER_REGISTRY_REDHAT=$(DOCKER_REGISTRY_REDHAT) -DTESTRUNNER_HOST=$(shell oc get routes | grep testrunner | awk '{print $$2}') -DTESTRUNNER_PORT=${_TESTRUNNER_PORT} clean test -f services/functional-tests/pom.xml $(ADDITIONAL_ARGUMENTS)
.PHONY: test-functional

deploy-testrunner-route:
	oc delete service testrunner-http || true
	oc delete route testrunner || true
	oc create -f ./services/functional-tests/src/test/resources/eap7-testrunner-service.yaml
	oc create -f ./services/functional-tests/src/test/resources/eap7-testrunner-route.yaml
.PHONY: deploy-testrunner-route

test-unit:
	cekit test $(DEV_IMAGE_FULL_NAME)
.PHONY: test-unit

_relist-template-service-broker:
	# This one is very hacky - the idea is to increase the relist request counter by 1. This way we ask the Template
	# Service Broker to refresh all templates. The rest of the complication is due to how Makefile parses file.
	RELIST_TO_BE_SET=`expr $(shell oc get ClusterServiceBroker/template-service-broker --template={{.spec.relistRequests}}) + 1` && \
	oc patch ClusterServiceBroker/template-service-broker -p '{"spec":{"relistRequests": '$$RELIST_TO_BE_SET'}}'
.PHONY: _relist-template-service-broker

_install_templates_in_openshift_namespace:
	oc create -f services/cache-service-template.yaml -n openshift || true
	oc create -f services/datagrid-service-template.yaml -n openshift || true
.PHONY: _install_templates_in_openshift_namespace

install-templates-in-openshift-namespace: _install_templates_in_openshift_namespace _relist-template-service-broker
.PHONY: install-templates-in-openshift-namespace

install-templates:
	oc create -f services/cache-service-template.yaml || true
	oc create -f services/datagrid-service-template.yaml || true
.PHONY: install-templates

clear-templates:
	oc delete all,secrets,sa,templates,configmaps,daemonsets,clusterroles,rolebindings,serviceaccounts --selector=template=cache-service || true
	oc delete all,secrets,sa,templates,configmaps,daemonsets,clusterroles,rolebindings,serviceaccounts --selector=template=datagrid-service || true
.PHONY: clear-templates

test-cache-service-manually:
	oc set image-lookup $(DEV_IMAGE_NAME)
	oc new-app cache-service \
	-p APPLICATION_USER=test \
	-p APPLICATION_PASSWORD=test \
	-p IMAGE=$(_DEV_IMAGE_STREAM) \
	-e SCRIPT_DEBUG=true
	oc expose svc/cache-service || true
	oc get routes
.PHONY: test-cache-service-manually

test-datagrid-service-manually:
	oc set image-lookup $(DEV_IMAGE_NAME)
	oc new-app datagrid-service \
	-p APPLICATION_USER=test \
	-p APPLICATION_PASSWORD=test \
	-p IMAGE=$(_DEV_IMAGE_STREAM) \
	-e SCRIPT_DEBUG=true
	oc expose svc/datagrid-service || true
	oc get routes
.PHONY: test-datagrid-service-manually

clean-maven:
	$(MVN_COMMAND) clean -f services/functional-tests/pom.xml || true
.PHONY: clean-maven

clean-docker:
	sudo docker container prune -f
	sudo docker rmi -f $(shell docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'datagrid|eap') || true
	rm -rf target-docker
.PHONY: clean-docker

clean: clean-docker clean-maven stop-openshift
.PHONY: clean

test-ci: clean start-openshift-with-catalog login-to-openshift prepare-openshift-project build-image push-image-to-local-openshift test-functional stop-openshift
.PHONY: test-ci

#Before running this target, login to the remote OpenShift from console in whatever way recommended by the provider
test-remote: clean-docker clean-maven prepare-openshift-project build-image push-image-to-online-openshift test-functional
.PHONY: test-remote

test-remote-with-pull: clean-docker clean-maven prepare-openshift-project pull-image push-image-to-online-openshift test-functional
.PHONY: test-remote-with-pull

clean-ci: stop-openshift clean-docker #avoid cleaning Maven as we need results to be reported by the job
.PHONY: clean-ci

run-docker: build-image
	$(shell mkdir -p ./services/capacity-tests/target/heapdumps)
	$(shell chmod 777 ./services/capacity-tests/target/heapdumps)
	docker run --privileged=true -m $(DOCKER_MEMORY) --memory-swappiness=0 --memory-swap $(DOCKER_MEMORY) -e APPLICATION_USER=test -e APPLICATION_PASSWORD=test -e KEYSTORE_FILE=/tmp/keystores/keystore_server.jks -e DEBUG=true -e KEYSTORE_PASSWORD=secret -v $(shell pwd)/services/capacity-tests/src/test/resources:/tmp/keystores -v $(shell pwd)/services/capacity-tests/target/heapdumps:/tmp/heapdumps $(ADDITIONAL_ARGUMENTS) $(DEV_IMAGE_FULL_NAME)
.PHONY: run-docker

test-capacity:
	$(MVN_COMMAND) clean test -f services/capacity-tests/pom.xml $(ADDITIONAL_ARGUMENTS)
.PHONY: test-capacity

run-cache-service-locally: stop-openshift start-openshift-with-catalog login-to-openshift prepare-openshift-project build-image push-image-to-local-openshift install-templates test-cache-service-manually
.PHONY: run-cache-service-locally

run-datagrid-service-locally: stop-openshift start-openshift-with-catalog login-to-openshift prepare-openshift-project build-image push-image-to-local-openshift install-templates test-datagrid-service-manually
.PHONY: run-datagrid-service-locally

#Before running this target, login to the remote OpenShift from console in whatever way recommended by the provider, make sure you specify the _TEST_PROJECT and OPENSHIFT_ONLINE_REGISTRY variables
run-cache-service-remotely: clean-docker clean-maven prepare-openshift-project build-image push-image-to-online-openshift install-templates test-cache-service-manually
.PHONY: test-online
