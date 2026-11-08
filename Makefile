build:
	bazel build //...

test:
	bazel test //...

format:
	bazel run //tools/format
