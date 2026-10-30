REPO_ROOT    := $(shell cd .. && pwd)
SERVER_DIR   ?= $(REPO_ROOT)/Server
DEPLOY_DIR   := $(SERVER_DIR)/extenders/file_host
GO           ?= go

OUT := $(DEPLOY_DIR)/service_filehost.so

.PHONY: all clean deploy

all: $(OUT) deploy

$(OUT): *.go
	@mkdir -p "$(DEPLOY_DIR)"
	@echo "  BUILD  service_filehost.so"
	@CGO_ENABLED=1 $(GO) build -buildmode=plugin -ldflags="-s -w" -o "$(OUT)" .
	@echo "  DEPLOY $(OUT)"

deploy:
	@mkdir -p "$(DEPLOY_DIR)"
	@cp config.yaml ax_config.axs "$(DEPLOY_DIR)/"

clean:
	@rm -f "$(OUT)"
	@echo "  CLEAN  done"
