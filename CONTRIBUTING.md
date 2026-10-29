# Contributing

Thanks for helping. This project follows the shared [alexisbcz Odin standards](https://github.com/alexisbcz/odin-standards/blob/main/STANDARDS.md). The short version is below.

## Before you open a pull request

Run the same checks as CI:

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do
vale sync && vale *.md
```

All three must pass with zero errors.

## Code

- Use snake_case for procedures and variables, Ada_Case for types, and SCREAMING_SNAKE_CASE for constants.
- Give every allocating procedure an `allocator := context.allocator` parameter and a matching destroy or delete procedure.
- Return `(T, Error)` from fallible procedures. Don't panic in library code.
- Write a doc comment for every exported declaration.
- Add a test under `tests/` for every bug fix and every new procedure. Wrap allocations in the tracking allocator from `tests/helpers_test.odin` so leaks fail the test.
- Add a byte-exact test against the [MessagePack specification](https://github.com/msgpack/msgpack/blob/master/spec.md) when you touch a format.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). Write an imperative subject of 72 characters or fewer, a blank line, then a body of `-` bullet points that explain what changed and why:

```text
fix: reject map32 headers longer than the input

- read_map_header trusted the declared count and let callers allocate it
- return Decode_Error.Unexpected_Eof before any allocation happens
```

## Changelog

Add a line under `## [Unreleased]` in `CHANGELOG.md` for every change that users can see.
