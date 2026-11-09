ifndef CCPROOT
	export CCPROOT=$(GOPATH)/src/github.com/ivorysql/ivory-containers
endif

# Default values if not already set
CCP_BASEOS ?= ubi9
BASE_IMAGE_OS ?= $(CCP_BASEOS)
#BASE_IMAGE_OS ?= rockylinux/rockylinux:8-ubi
CCP_IMAGE_PREFIX ?= ivorysql
CCP_PGVERSION ?= 18
CCP_PG_FULLVERSION ?= 18.1
CCP_IVYVERSION ?= 1.1
CCP_IVY_FULLVERSION ?= 5.1
CCP_PATRONI_VERSION ?= 4.0.7
CCP_BACKREST_VERSION ?= 2.56.0
CCP_VERSION ?= 1
CCP_POSTGIS_VERSION ?= 3.5
CCP_POSTGIS_FULL_VERSION ?= 3.5.4
CCP_PGADMIN_VERSION ?= 9.9
CCP_PGBOUNCER_VERSION ?= 1.24.0
CCP_PGEXPORTER_VERSION ?= 0.17.0
CCP_IVYO_VERSION ?= 5.1
CCP_IMAGE_TAG ?= $(CCP_BASEOS)-$(CCP_IVY_FULLVERSION)-$(CCP_IVYO_VERSION)-$(CCP_VERSION)
CCP_POSTGIS_IMAGE_TAG ?= $(CCP_BASEOS)-$(CCP_POSTGIS_VERSION)-$(CCP_IVYO_VERSION)-$(CCP_VERSION)
PACKAGER ?= dnf

# Valid values: buildah (default), docker
IMGBUILDER ?= docker
# Determines whether or not images should be pushed to the local docker daemon when building with
# a tool other than docker (e.g. when building with buildah)
IMG_PUSH_TO_DOCKER_DAEMON ?= true 
# The utility to use when pushing/pulling to and from an image repo (e.g. docker or buildah)
IMG_PUSHER_PULLER ?= docker
# Defines the sudo command that should be prepended to various build commands when rootless builds are
# not enabled
IMGCMDSUDO=
ifneq ("$(IMG_ROOTLESS_BUILD)", "true")
	IMGCMDSUDO=sudo --preserve-env
endif
IMGCMDSTEM=$(IMGCMDSUDO) buildah bud --layers $(SQUASH)
DFSET=$(CCP_BASEOS)
DOCKERBASEREGISTRY=registry.access.redhat.com/

# Default the buildah format to docker to ensure it is possible to pull the images from a docker
# repository using docker (otherwise the images may not be recognized)
export BUILDAH_FORMAT ?= docker

# Allows simplification of IMGBUILDER switching
ifeq ("$(IMGBUILDER)","docker")
	IMGCMDSTEM=docker build
endif

# Allows consolidation of ubi/rhel Dockerfile sets
ifeq ("$(CCP_BASEOS)", "ubi9")
        DFSET=rhel
endif

.PHONY:	all license pgbackrest-images pg-independent-images ivyimages

# list of image names, helpful in pushing
images = ivorysql-ivorysql \
	ivorysql-pgbackrest \
	ivorysql-pgbouncer \
	ivorysql-pgadmin4 \
	ivorysql-postgis \
	ivorysql-postgres-exporter

# Default target
all: ivyimages pg-independent-images pgbackrest-images

# Build images that either don't have a PG dependency or using the latest PG version is all that is needed
pg-independent-images: pgbouncer pgadmin4 pgexporter

# Build images that require a specific postgres version - ordered for potential concurrent benefits
ivyimages: ivorysql ivorysql-postgis

# Build images based on pgBackRest
pgbackrest-images: pgbackrest

#===========================================
# Targets generating pg-based images
#===========================================

pgadmin4: pgadmin4-img-$(IMGBUILDER)
pgexporter: pgexporter-img-$(IMGBUILDER)
pgbackrest: pgbackrest-ivyimg-$(IMGBUILDER)
pgbouncer: pgbouncer-img-$(IMGBUILDER)
ivorysql: ivorysql-ivyimg-$(IMGBUILDER)
ivorysql-postgis: ivorysql-gis-ivyimg-$(IMGBUILDER)

#===========================================
# Pattern-based image generation targets
#===========================================

$(CCPROOT)/build/%/Dockerfile:
	$(error No Dockerfile found for $* naming pattern: [$@])

# ----- Base Image -----
ccbase-image: ccbase-image-$(IMGBUILDER)

ccbase-image-build: build-pgbackrest license $(CCPROOT)/build/base/Dockerfile
	$(IMGCMDSTEM) \
		--network=host \
		-f $(CCPROOT)/build/base/Dockerfile \
		-t ivorysql/base:$(CCP_IMAGE_TAG) \
		--build-arg BASEOS=$(CCP_BASEOS) \
		--build-arg RELVER=$(CCP_VERSION) \
		--build-arg PACKAGER=$(PACKAGER) \
		--build-arg DOCKERBASEREGISTRY=$(DOCKERBASEREGISTRY) \
		--build-arg BASE_IMAGE_OS=$(BASE_IMAGE_OS) \
		$(CCPROOT)

ccbase-image-buildah: ccbase-image-build ;
# only push to docker daemon if variable IMG_PUSH_TO_DOCKER_DAEMON is set to "true"
ifeq ("$(IMG_PUSH_TO_DOCKER_DAEMON)", "true")
	sudo --preserve-env buildah push $(CCP_IMAGE_PREFIX)/base:$(CCP_IMAGE_TAG) docker-daemon:$(CCP_IMAGE_PREFIX)/base:$(CCP_IMAGE_TAG)
endif

ccbase-image-docker: ccbase-image-build

# only push to docker daemon if variable IMG_PUSH_TO_DOCKER_DAEMON is set to "true"
ifeq ("$(IMG_PUSH_TO_DOCKER_DAEMON)", "true")
	sudo --preserve-env buildah push $(CCP_IMAGE_PREFIX)/crunchy-base-ext:$(CCP_IMAGE_TAG) docker-daemon:$(CCP_IMAGE_PREFIX)/crunchy-base-ext:$(CCP_IMAGE_TAG)
endif

# ----- Special case pg-based image (postgres) -----
# Special case args: BACKREST_VER
ivorysql-ivyimg-build: ccbase-image $(CCPROOT)/build/ivory/Dockerfile_multi 
	$(IMGCMDSTEM) \
		--network=host \
		-f $(CCPROOT)/build/ivory/Dockerfile_multi \
		-t $(CCP_IMAGE_PREFIX)/ivorysql:$(CCP_IMAGE_TAG) \
		--build-arg BASEOS=$(CCP_BASEOS) \
		--build-arg BASEVER=$(CCP_VERSION) \
		--build-arg PG_FULL=$(CCP_PG_FULLVERSION) \
		--build-arg IVY_FULL=$(CCP_IVY_FULLVERSION) \
		--build-arg IVYO_VER=$(CCP_IVYO_VERSION) \
		--build-arg PG_MAJOR=$(CCP_PGVERSION) \
		--build-arg IVY_MAJOR=$(CCP_IVYVERSION) \
		--build-arg PREFIX=$(CCP_IMAGE_PREFIX) \
		--build-arg BACKREST_VER=$(CCP_BACKREST_VERSION) \
		--build-arg PACKAGER=$(PACKAGER) \
		--build-arg BASE_IMAGE_NAME=ivorysql/base \
		--build-arg PATRONI_VER=$(CCP_PATRONI_VERSION) \
		$(CCPROOT)

ivorysql-ivyimg-buildah: ivorysql-ivyimg-build ;
# only push to docker daemon if variable IMG_PUSH_TO_DOCKER_DAEMON is set to "true"
ifeq ("$(IMG_PUSH_TO_DOCKER_DAEMON)", "true")
	sudo --preserve-env buildah push $(CCP_IMAGE_PREFIX)/ivorysql:$(CCP_IMAGE_TAG) docker-daemon:$(CCP_IMAGE_PREFIX)/ivorysql:$(CCP_IMAGE_TAG)
endif

ivorysql-ivyimg-docker: ivorysql-ivyimg-build

# ----- Special case ivy-based image (postgres-gis-base) -----
# Used as the base for the postgres-gis image.
postgres-gis-base-ivyimg-build: ccbase-image-build $(CCPROOT)/build/ivory/Dockerfile_multi
	$(IMGCMDSTEM) \
		--network=host \
		-f $(CCPROOT)/build/ivory/Dockerfile_multi \
		-t $(CCP_IMAGE_PREFIX)/ivorysql-postgres-gis-base:$(CCP_IMAGE_TAG) \
		--build-arg BASEOS=$(CCP_BASEOS) \
		--build-arg BASEVER=$(CCP_VERSION) \
		--build-arg PG_FULL=$(CCP_PG_FULLVERSION) \
		--build-arg PG_MAJOR=$(CCP_PGVERSION) \
		--build-arg PREFIX=$(CCP_IMAGE_PREFIX) \
		--build-arg BACKREST_VER=$(CCP_BACKREST_VERSION) \
		--build-arg PACKAGER=$(PACKAGER) \
		--build-arg PATRONI_VER=$(CCP_PATRONI_VERSION) \
		--build-arg IVY_MAJOR=$(CCP_IVYVERSION) \
		--build-arg IVY_FULL=$(CCP_IVY_FULLVERSION) \
		--build-arg IVYO_VER=$(CCP_IVYO_VERSION) \
		--build-arg BASE_IMAGE_NAME=ivorysql/base \
		$(CCPROOT)

postgres-gis-base-ivyimg-buildah: postgres-gis-base-ivyimg-build ;
# only push to docker daemon if variable IMG_PUSH_TO_DOCKER_DAEMON is set to "true"
ifeq ("$(IMG_PUSH_TO_DOCKER_DAEMON)", "true")
	sudo --preserve-env buildah push $(CCP_IMAGE_PREFIX)/ivorysql-postgres-gis-base:$(CCP_IMAGE_TAG) docker-daemon:$(CCP_IMAGE_PREFIX)/ivorysql-postgres-gis-base:$(CCP_IMAGE_TAG)
endif

# ----- Special case pg-based image (postgres-gis) -----
# Special case args: POSTGIS_LBL
ivorysql-gis-ivyimg-build: postgres-gis-base-ivyimg-build $(CCPROOT)/build/postgres-gis/Dockerfile
	$(IMGCMDSTEM) \
		--network=host \
		-f $(CCPROOT)/build/postgres-gis/Dockerfile \
		-t $(CCP_IMAGE_PREFIX)/postgis:$(CCP_POSTGIS_IMAGE_TAG) \
		--build-arg BASEOS=$(CCP_BASEOS) \
		--build-arg BASEVER=$(CCP_VERSION) \
		--build-arg PG_FULL=$(CCP_PG_FULLVERSION) \
		--build-arg IVY_FULL=$(CCP_IVY_FULLVERSION) \
		--build-arg PREFIX=$(CCP_IMAGE_PREFIX) \
		--build-arg PACKAGER=$(PACKAGER) \
		--build-arg IVYO_VER=$(CCP_IVYO_VERSION) \
		$(CCPROOT)

ivorysql-gis-ivyimg-buildah: ivorysql-gis-ivyimg-build ;
# only push to docker daemon if variable IMG_PUSH_TO_DOCKER_DAEMON is set to "true"
ifeq ("$(IMG_PUSH_TO_DOCKER_DAEMON)", "true")
	sudo --preserve-env buildah push $(CCP_IMAGE_PREFIX)/ivorysql-postgres-gis:$(CCP_POSTGIS_IMAGE_TAG) docker-daemon:$(CCP_IMAGE_PREFIX)/ivorysql-postgres-gis:$(CCP_POSTGIS_IMAGE_TAG)
endif

ivorysql-gis-ivyimg-docker: ivorysql-gis-ivyimg-build

# ----- Special case image (pgbackrest) -----

# build the needed binary
build-pgbackrest:
	go build -o bin/pgbackrest/pgbackrest ./cmd/pgbackrest

# Special case args: BACKREST_VER
pgbackrest-ivyimg-build: ccbase-image build-pgbackrest $(CCPROOT)/build/pgbackrest/Dockerfile
	$(IMGCMDSTEM) \
		-f $(CCPROOT)/build/pgbackrest/Dockerfile \
		-t $(CCP_IMAGE_PREFIX)/pgbackrest:$(CCP_BASEOS)-$(CCP_BACKREST_VERSION)-$(CCP_IVYO_VERSION)-$(CCP_VERSION) \
		--build-arg BASEOS=$(CCP_BASEOS) \
		--build-arg BASEVER=$(CCP_VERSION) \
		--build-arg IVY_FULL=$(CCP_IVY_FULLVERSION) \
		--build-arg PREFIX=$(CCP_IMAGE_PREFIX) \
		--build-arg BACKREST_VER=$(CCP_BACKREST_VERSION) \
		--build-arg PACKAGER=$(PACKAGER) \
		--build-arg BASE_IMAGE_NAME=ivorysql/base \
		--build-arg IVYO_VER=$(CCP_IVYO_VERSION) \
		$(CCPROOT)

pgbackrest-ivyimg-buildah: pgbackrest-ivyimg-build ;
# only push to docker daemon if variable IMG_PUSH_TO_DOCKER_DAEMON is set to "true"
ifeq ("$(IMG_PUSH_TO_DOCKER_DAEMON)", "true")
	sudo --preserve-env buildah push $(CCP_IMAGE_PREFIX)/pgbackrest:$(CCP_IMAGE_TAG) docker-daemon:$(CCP_IMAGE_PREFIX)/pgbackrest:$(CCP_IMAGE_TAG)
endif

pgbackrest-ivyimg-docker: pgbackrest-ivyimg-build

pgexporter-img-build: $(CCPROOT)/build/pgexporter/Dockerfile
	$(IMGCMDSTEM) \
		--network=host \
		-f $(CCPROOT)/build/pgexporter/Dockerfile \
		-t $(CCP_IMAGE_PREFIX)/postgres-exporter:$(CCP_BASEOS)-$(CCP_PGEXPORTER_VERSION)-$(CCP_IVYO_VERSION)-$(CCP_VERSION) \
		--build-arg PG_MAJOR=$(CCP_PGVERSION) \
		$(CCPROOT)

# Special case args: CCP_PGADMIN_VERSION
pgadmin4-img-build: $(CCPROOT)/build/pgadmin4/Dockerfile
	$(IMGCMDSTEM) \
		--network=host \
		-f $(CCPROOT)/build/pgadmin4/Dockerfile \
		-t $(CCP_IMAGE_PREFIX)/pgadmin:$(CCP_BASEOS)-$(CCP_PGADMIN_VERSION)-$(CCP_IVYO_VERSION)-$(CCP_VERSION) \
		--build-arg PG_MAJOR=$(CCP_PGVERSION) \
		--build-arg PACKAGER=$(PACKAGER) \
		$(CCPROOT)

pgadmin4-img-buildah: pgadmin4-img-build ;
# only push to docker daemon if variable IMG_PUSH_TO_DOCKER_DAEMON is set to "true"
ifeq ("$(IMG_PUSH_TO_DOCKER_DAEMON)", "true")
	sudo --preserve-env buildah push $(CCP_IMAGE_PREFIX)/pgadmin:$(CCP_BASEOS)-$(CCP_PGADMIN_VERSION)-$(CCP_IVYO_VERSION)-$(CCP_VERSION) docker-daemon:$(CCP_IMAGE_PREFIX)/pgadmin:$(CCP_BASEOS)-$(CCP_PGADMIN_VERSION)-$(CCP_IVYO_VERSION)-$(CCP_VERSION)
endif

pgadmin-img-docker: pgadmin-img-build

# Special case args: CCP_PGBOUNCER_VERSION
pgbouncer-img-build: $(CCPROOT)/build/pgbouncer/Dockerfile
	$(IMGCMDSTEM) \
		-f $(CCPROOT)/build/pgbouncer/Dockerfile \
		-t $(CCP_IMAGE_PREFIX)/pgbouncer:$(CCP_BASEOS)-$(CCP_PGBOUNCER_VERSION)-$(CCP_IVYO_VERSION)-$(CCP_VERSION) \
		--build-arg PG_MAJOR=$(CCP_PGVERSION) \
		--build-arg PGBOUNCER_VER=$(CCP_PGBOUNCER_VERSION) \
		--build-arg PACKAGER=$(PACKAGER) \
		$(CCPROOT)

pgbouncer-img-buildah: pgbouncer-img-build ;
# only push to docker daemon if variable IMG_PUSH_TO_DOCKER_DAEMON is set to "true"
ifeq ("$(IMG_PUSH_TO_DOCKER_DAEMON)", "true")
	sudo --preserve-env buildah push $(CCP_IMAGE_PREFIX)/crunchy-pgbouncer:$(CCP_IMAGE_TAG) docker-daemon:$(CCP_IMAGE_PREFIX)/crunchy-pgbouncer:$(CCP_IMAGE_TAG)
endif

pgbouncer-img-docker: pgbouncer-img-build

# ----- Extra images -----
%-img-build: ccbase-image $(CCPROOT)/build/%/Dockerfile
	$(IMGCMDSTEM) \
		-f $(CCPROOT)/build/$*/Dockerfile \
		-t $(CCP_IMAGE_PREFIX)/ivorysql-$*:$(CCP_IMAGE_TAG) \
		--build-arg BASEOS=$(CCP_BASEOS) \
		--build-arg BASEVER=$(CCP_VERSION) \
		--build-arg PG_FULL=$(CCP_PG_FULLVERSION) \
		--build-arg PG_MAJOR=$(CCP_PGVERSION) \
		--build-arg PREFIX=$(CCP_IMAGE_PREFIX) \
		--build-arg DFSET=$(DFSET) \
		--build-arg PACKAGER=$(PACKAGER) \
		$(CCPROOT)

%-img-buildah: %-img-build ;
# only push to docker daemon if variable IMG_PUSH_TO_DOCKER_DAEMON is set to "true"
ifeq ("$(IMG_PUSH_TO_DOCKER_DAEMON)", "true")
	sudo --preserve-env buildah push $(CCP_IMAGE_PREFIX)/ivorysql-$*:$(CCP_IMAGE_TAG) docker-daemon:$(CCP_IMAGE_PREFIX)/ivorysql-$*:$(CCP_IMAGE_TAG)
endif

%-img-docker: %-img-build ;

#=================
# Utility targets
#=================
setup:
	$(CCPROOT)/bin/install-deps.sh

docbuild:
	cd $(CCPROOT) && ./generate-docs.sh

license:
	./bin/license_aggregator.sh

push: push-gis $(images:%=push-%) ;

push-gis:
	$(IMG_PUSHER_PULLER) push $(CCP_IMAGE_PREFIX)/postgis:$(CCP_POSTGIS_IMAGE_TAG)

push-%:
	$(IMG_PUSHER_PULLER) push $(CCP_IMAGE_PREFIX)/$*:$(CCP_IMAGE_TAG)

-include Makefile.build
