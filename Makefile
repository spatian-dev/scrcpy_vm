.PHONY: check test lint

check:
	bash -n scrcpy_vm.sh && bash -n tests/test_cli.sh

test:
	bash tests/test_cli.sh

lint:
	shellcheck scrcpy_vm.sh tests/test_cli.sh
