# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-29

### Added

- `Encoder` with `write_nil`, `write_bool`, `write_int`, `write_uint`, `write_f32`, `write_f64`, `write_str`, `write_bin`, `write_array_header`, `write_map_header`, `write_ext` and `write_timestamp`. Each write picks the smallest format.
- `Decoder` with `peek_kind`, matching `read_*` procedures and `skip`. Reads never allocate, and a failed read leaves the position unchanged.
- Timestamp extension support in all three layouts, plus `timestamp_from_time` and `timestamp_to_time`.
- Dynamic `Value` type with `decode_value`, `read_value`, `encode_value`, `write_value`, `value_destroy`, `value_equal` and `map_get`.
- Reflection-based `marshal`, `marshal_into`, `unmarshal`, `read_into` and `destroy`, with `msgpack:"name"`, `msgpack:"-"` and `msgpack:",omitempty"` struct tags.
- Protection against hostile input: the decoder checks declared lengths against the remaining bytes, `max_depth` bounds nesting, and integer decoding checks the destination range.
- Examples `basic` and `stream`.

[Unreleased]: https://github.com/alexisbcz/odin-msgpack/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/alexisbcz/odin-msgpack/releases/tag/v0.1.0
