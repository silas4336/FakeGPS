.PHONY: help install build run doctor uninstall clean

help:        ## 顯示可用指令
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

install:     ## 安裝（依賴 + 編譯 + 權限 + 裝到 /Applications）
	@./install.sh

build:       ## 只編譯 Universal App 到 ./build
	@./build.sh ./build

run: build   ## 編譯並開啟（用 ./build 版本）
	@open ./build/FakeGPS.app

doctor:      ## 診斷環境是否就緒
	@./doctor.sh

uninstall:   ## 解除安裝
	@./uninstall.sh

clean:       ## 清除編譯產物
	@rm -rf ./build
	@echo "已清除 ./build"
