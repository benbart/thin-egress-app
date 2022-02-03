# TODO(reweeden): docs

SOURCES := \
	lambda/app.py \
	lambda/tea_bumper.py \
	lambda/update_lambda.py

RESOURCES := \
	lambda/templates/base.html \
	lambda/templates/error.html \
	lambda/templates/profile.html \
	lambda/templates/root.html

# Output directory
DIR := dist
EMPTY := $(DIR)/empty
# Temporary artifacts
DIST_SOURCES := $(SOURCES:lambda/%=$(DIR)/code/%)
DIST_RESOURCES := $(RESOURCES:lambda/%=$(DIR)/code/%)

BUCKET_MAP_OBJECT_KEY := $(CONFIG_PREFIX)bucket-map.yaml

DATE := $(shell date --utc "+%b %d %Y, %T %Z")
DATE_SHORT := $(shell date --utc "+%Y%m%dT%H%M%S")
BUILD_ID := $(shell git rev-parse --short HEAD)

#####################
# Deployment Config #
#####################

# A tag to discriminate between artifacts of the same name. The tag should be
# different for each build.
S3_ARTIFACT_TAG = $(DATE_SHORT)


# Include custom configuration
CONFIG:
	@echo "It looks like you are building TEA for the first time.\nPlease review the configuration in '$@' and run Make again.\n"
	@cp --no-clobber CONFIG.example CONFIG
	@exit 1

include CONFIG


.DEFAULT_GOAL := build

##############################
# Local building/development #
##############################

# Build everything
.PHONY: build
build: \
	$(DIR)/thin-egress-app-code.zip \
	$(DIR)/thin-egress-app-dependencies.zip \
	$(DIR)/thin-egress-app.yaml

# Build individual components
.PHONY: dependencies
dependencies: $(DIR)/thin-egress-app-dependencies.zip
	@echo "Built dependency layer for version ${BUILD_ID}"

.PHONY: code
code: $(DIR)/thin-egress-app-code.zip
	@echo "Built code for version ${BUILD_ID}"

.PHONY: yaml
yaml: $(DIR)/thin-egress-app.yaml
	@echo "Built CloudFormation template for version ${BUILD_ID}"

.PHONY: clean
clean:
	rm -r $(DIR)

$(DIR)/thin-egress-app-dependencies.zip: requirements.txt | $(DIR)
	WORKSPACE=`pwd` DEPENDENCYLAYERFILENAME=$(DIR)/thin-egress-app-dependencies.zip build/dependency_builder.sh

.SECONDARY: $(DIST_RESOURCES)
$(DIST_RESOURCES): $(DIR)/code/%: lambda/%
	@mkdir -p $(@D)
	cp $< $@

.SECONDARY: $(DIST_SOURCES)
$(DIST_SOURCES): $(DIR)/code/%: lambda/%
	@mkdir -p $(@D)
	cp $< $@
	sed -i "s/<BUILD_ID>/${BUILD_ID}/g" $@

$(DIR)/thin-egress-app-code.zip: $(DIST_SOURCES) $(DIST_RESOURCES) | $(DIR)/code
	cd $(DIR)/code && zip -r ../thin-egress-app-code.zip .

$(DIR)/bucket-map.yaml: config/bucket-map-template.yaml
	cp $< $@

$(DIR)/thin-egress-app.yaml: cloudformation/thin-egress-app.yaml | $(DIR)
	cp cloudformation/thin-egress-app.yaml $(DIR)/thin-egress-app.yaml
ifdef CF_DEFAULT_CODE_BUCKET
	sed -i -e "s;asf.public.code;${CF_DEFAULT_CODE_BUCKET};" $(DIR)/thin-egress-app.yaml
endif
	sed -i -e "s;<DEPENDENCY_ARCHIVE_PATH_FILENAME>;${CF_DEFAULT_DEPENDENCY_ARCHIVE_KEY};" $(DIR)/thin-egress-app.yaml
	sed -i -e "s;<CODE_ARCHIVE_PATH_FILENAME>;${CF_DEFAULT_CODE_ARCHIVE_KEY};" $(DIR)/thin-egress-app.yaml
	sed -i -e "s;<BUILD_ID>;${CF_BUILD_VERSION};g" $(DIR)/thin-egress-app.yaml
	sed -i -e "s;^Description:.*;Description: \"${CF_DESCRIPTION}\";" $(DIR)/thin-egress-app.yaml

##############
# Deployment #
##############
# TODO(reweeden): Terraform?

# Empty targets so we don't re-deploy stuff that is unchanged. Technically they
# might not be empty, but their purpose is the same.
# https://www.gnu.org/software/make/manual/html_node/Empty-Targets.html

$(EMPTY)/.deploy-dependencies: $(DIR)/thin-egress-app-dependencies.zip | $(EMPTY)
	@echo "Deploying dependencies"
	$(AWS) s3 cp --profile=$(AWS_PROFILE) $< \
		s3://$(CODE_BUCKET)/$(CODE_PREFIX)dependencies-$(S3_ARTIFACT_TAG).zip

	@echo $(S3_ARTIFACT_TAG) > $(EMPTY)/.deploy-dependencies

$(EMPTY)/.deploy-code: $(DIR)/thin-egress-app-code.zip | $(EMPTY)
	@echo "Deploying code"
	$(AWS) s3 cp --profile=$(AWS_PROFILE) \
		$(DIR)/thin-egress-app-code.zip \
		s3://$(CODE_BUCKET)/$(CODE_PREFIX)code-$(S3_ARTIFACT_TAG).zip

	@echo $(S3_ARTIFACT_TAG) > $(EMPTY)/.deploy-code

$(EMPTY)/.deploy-bucket-map: $(DIR)/bucket-map.yaml | $(EMPTY)
	@echo "Deploying bucket map"
	$(AWS) s3 cp --profile=$(AWS_PROFILE) $< \
		s3://$(CONFIG_BUCKET)/$(BUCKET_MAP_OBJECT_KEY)

	@touch $(EMPTY)/.deploy-bucket-map

# Optionally upload a bucket map if the user hasn't specified one
BUCKET_MAP_REQUIREMENT =
ifneq ($(BUCKET_MAP_OBJECT_KEY), $(CONFIG_PREFIX)/bucket-map.yaml)
BUCKET_MAP_REQUIREMENT = $(EMPTY)/.deploy-bucket-map
endif

.PHONY: $(EMPTY)/.deploy-stack
$(EMPTY)/.deploy-stack: $(DIR)/thin-egress-app.yaml $(EMPTY)/.deploy-dependencies $(EMPTY)/.deploy-code $(BUCKET_MAP_REQUIREMENT) | $(EMPTY)
	@echo "Deploying stack '$(STACK_NAME)'"
	$(AWS) cloudformation deploy --profile=$(AWS_PROFILE) \
						 --stack-name $(STACK_NAME) \
						 --template-file $(DIR)/thin-egress-app.yaml \
						 --capabilities CAPABILITY_NAMED_IAM \
						 --parameter-overrides \
						 	 LambdaCodeS3Key="$(CODE_PREFIX)code-`cat $(EMPTY)/.deploy-code`.zip" \
							 LambdaCodeDependencyArchive="$(CODE_PREFIX)dependencies-`cat $(EMPTY)/.deploy-dependencies`.zip" \
							 BucketMapFile=$(BUCKET_MAP_OBJECT_KEY) \
							 URSAuthCredsSecretName=$(URS_CREDS_SECRET_NAME) \
							 AuthBaseUrl=$(URS_URL) \
							 ConfigBucket=$(CONFIG_BUCKET) \
							 LambdaCodeS3Bucket=$(CODE_BUCKET) \
							 PermissionsBoundaryName= \
							 PublicBucketsFile="" \
							 PrivateBucketsFile="" \
							 BucketnamePrefix=$(BUCKETNAME_PREFIX) \
							 DownloadRoleArn="" \
							 DownloadRoleInRegionArn="" \
							 HtmlTemplateDir= \
							 StageName=API \
							 Loglevel=DEBUG \
							 Logtype=json \
							 Maturity=DEV\
							 PrivateVPC= \
							 VPCSecurityGroupIDs= \
							 VPCSubnetIDs= \
							 EnableApiGatewayLogToCloudWatch="False" \
							 DomainName=$(DOMAIN_NAME-"") \
							 DomainCertArn=$(DOMAIN_CERT_ARN-"")  \
							 CookieDomain=$(COOKIE_DOMAIN-"") \
							 LambdaTimeout=$(LAMBDA_TIMEOUT) \
							 LambdaMemory=$(LAMBDA_MEMORY) \
							 JwtAlgo=$(JWTALGO) \
							 JwtKeySecretName=$(JWT_KEY_SECRET_NAME) \
							 UseReverseBucketMap="False" \
							 UseCorsCookieDomain="False"

	@touch $(EMPTY)/.deploy-stack

# Deploy everything
.PHONY: deploy
deploy: deploy-code deploy-dependencies deploy-stack

# Deploy individual components
.PHONY: deploy-code
deploy-code: $(EMPTY)/.deploy-code

.PHONY: deploy-dependencies
deploy-dependencies: $(EMPTY)/.deploy-dependencies

.PHONY: deploy-bucket-map
deploy-bucket-map: $(EMPTY)/.deploy-bucket-map

.PHONY: deploy-stack
deploy-stack: $(EMPTY)/.deploy-stack

# Remove the empty target files so that aws commands will be run again
.PHONY: cleandeploy
cleandeploy:
	rm -r $(EMPTY)

###############
# Development #
###############

.PHONY: test
test:
	pytest --cov=lambda --cov-report=term-missing --cov-branch tests

###########
# Helpers #
###########

$(EMPTY):
	mkdir -p $(EMPTY)

$(DIR):
	mkdir -p $(DIR)

$(DIR)/code:
	mkdir -p $(DIR)/code
