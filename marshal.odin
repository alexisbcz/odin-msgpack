package msgpack

import "base:runtime"
import "core:reflect"
import "core:strings"
import "core:time"

/*
marshal encodes any Odin value as MessagePack using runtime type information.

The mapping is:
- booleans, integers of every width and endianness, `rune` and floats map to
  the matching MessagePack scalar. `f16` widens to float32.
- `string` and `cstring` map to str.
- `[]byte`, `[dynamic]byte` and `[N]byte` map to bin.
- other slices, dynamic arrays, fixed arrays and enumerated arrays map to array.
- maps map to map. Iteration order of Odin maps is unspecified.
- structs map to a map keyed by field name. A `msgpack:"name"` tag renames a
  field, `msgpack:"-"` skips it, and `msgpack:",omitempty"` skips it when it
  holds its zero value or an empty string, slice or map.
- enums map to their integer value.
- pointers and unions map to their target or active variant, or nil.
- Value, Timestamp, Extension and `time.Time` map to themselves; `time.Time`
  becomes a timestamp.

Inputs:
- v: the value to encode.
- allocator: allocates the result.

Returns:
- data: owned by the caller; free with `delete(data, allocator)`.
- err: `.Unsupported_Type` for types such as procedures and raw pointers,
  `.Nesting_Too_Deep` for pointer cycles, or an allocator error.
*/
marshal :: proc(v: any, allocator := context.allocator) -> (data: []byte, err: Error) {
	e: Encoder
	encoder_init(&e, 0, allocator) or_return
	if err = marshal_into(&e, v); err != nil {
		encoder_destroy(&e)
		return nil, err
	}
	return e.buf[:], nil
}

/*
marshal_into appends `v` to `e` with the same mapping as marshal. On failure
it removes any partial output, so the encoder holds what it held before.
*/
marshal_into :: proc(e: ^Encoder, v: any) -> (err: Error) {
	start := len(e.buf)
	defer if err != nil {
		resize(&e.buf, start)
	}
	return marshal_any(e, v, 0)
}

@(private)
marshal_any :: proc(e: ^Encoder, v: any, depth: int) -> Error {
	if depth > DEFAULT_MAX_DEPTH {
		return Encode_Error.Nesting_Too_Deep
	}
	if v.data == nil || v.id == nil {
		return write_nil(e)
	}

	switch v.id {
	case Value:
		return write_value(e, (^Value)(v.data)^)
	case Map:
		return write_value(e, (^Map)(v.data)^)
	case Array:
		return write_value(e, (^Array)(v.data)^)
	case Timestamp:
		return write_timestamp(e, (^Timestamp)(v.data)^)
	case Extension:
		x := (^Extension)(v.data)^
		return write_ext(e, x.type, x.data)
	case time.Time:
		return write_timestamp(e, timestamp_from_time((^time.Time)(v.data)^))
	}

	ti := reflect.type_info_base(type_info_of(v.id))
	#partial switch info in ti.variant {
	case reflect.Type_Info_Integer, reflect.Type_Info_Rune:
		x, ok := any_to_i128(v)
		if !ok {
			return Encode_Error.Unsupported_Type
		}
		return write_i128(e, x)

	case reflect.Type_Info_Enum:
		return marshal_any(e, any{v.data, info.base.id}, depth)

	case reflect.Type_Info_Float:
		switch f in reflect.any_core(v) {
		case f16:
			return write_f32(e, f32(f))
		case f16le:
			return write_f32(e, f32(f))
		case f16be:
			return write_f32(e, f32(f))
		case f32:
			return write_f32(e, f)
		case f32le:
			return write_f32(e, f32(f))
		case f32be:
			return write_f32(e, f32(f))
		case f64:
			return write_f64(e, f)
		case f64le:
			return write_f64(e, f64(f))
		case f64be:
			return write_f64(e, f64(f))
		}
		return Encode_Error.Unsupported_Type

	case reflect.Type_Info_Boolean:
		switch b in reflect.any_core(v) {
		case bool:
			return write_bool(e, b)
		case b8:
			return write_bool(e, bool(b))
		case b16:
			return write_bool(e, bool(b))
		case b32:
			return write_bool(e, bool(b))
		case b64:
			return write_bool(e, bool(b))
		}
		return Encode_Error.Unsupported_Type

	case reflect.Type_Info_String:
		if info.encoding != .UTF_8 {
			return Encode_Error.Unsupported_Type
		}
		if info.is_cstring {
			cs := (^cstring)(v.data)^
			if cs == nil {
				return write_nil(e)
			}
			return write_str(e, string(cs))
		}
		return write_str(e, (^string)(v.data)^)

	case reflect.Type_Info_Pointer:
		if info.elem == nil {
			return Encode_Error.Unsupported_Type
		}
		target := (^rawptr)(v.data)^
		if target == nil {
			return write_nil(e)
		}
		return marshal_any(e, any{target, info.elem.id}, depth + 1)

	case reflect.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(v.data)
		return marshal_sequence(e, raw.data, raw.len, info.elem, depth)

	case reflect.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(v.data)
		return marshal_sequence(e, raw.data, raw.len, info.elem, depth)

	case reflect.Type_Info_Array:
		return marshal_sequence(e, v.data, info.count, info.elem, depth)

	case reflect.Type_Info_Enumerated_Array:
		write_array_header(e, info.count) or_return
		for i in 0 ..< info.count {
			elem := rawptr(uintptr(v.data) + uintptr(i * info.elem_size))
			marshal_any(e, any{elem, info.elem.id}, depth + 1) or_return
		}
		return nil

	case reflect.Type_Info_Map:
		write_map_header(e, reflect.length(v)) or_return
		it: int
		for key, value in reflect.iterate_map(v, &it) {
			marshal_any(e, key, depth + 1) or_return
			marshal_any(e, value, depth + 1) or_return
		}
		return nil

	case reflect.Type_Info_Struct:
		return marshal_struct(e, v, info, depth)

	case reflect.Type_Info_Union:
		return marshal_any(e, reflect.get_union_variant(v), depth + 1)

	case reflect.Type_Info_Any:
		return marshal_any(e, (^any)(v.data)^, depth + 1)
	}
	return Encode_Error.Unsupported_Type
}

// marshal_sequence writes `count` elements starting at `data`; byte elements become one bin item.
@(private)
marshal_sequence :: proc(e: ^Encoder, data: rawptr, count: int, elem: ^reflect.Type_Info, depth: int) -> Error {
	if is_byte_type(elem) {
		return write_bin(e, ([^]byte)(data)[:count])
	}
	write_array_header(e, count) or_return
	for i in 0 ..< count {
		item := rawptr(uintptr(data) + uintptr(i * elem.size))
		marshal_any(e, any{item, elem.id}, depth + 1) or_return
	}
	return nil
}

@(private)
marshal_struct :: proc(e: ^Encoder, v: any, info: reflect.Type_Info_Struct, depth: int) -> Error {
	if .raw_union in info.flags {
		return Encode_Error.Unsupported_Type
	}
	count := 0
	for i in 0 ..< int(info.field_count) {
		if include_field(v, info, i) {
			count += 1
		}
	}
	write_map_header(e, count) or_return
	for i in 0 ..< int(info.field_count) {
		if !include_field(v, info, i) {
			continue
		}
		tag := parse_field_tag(info.names[i], info.tags[i])
		write_str(e, tag.name) or_return
		field := any{rawptr(uintptr(v.data) + info.offsets[i]), info.types[i].id}
		marshal_any(e, field, depth + 1) or_return
	}
	return nil
}

@(private)
include_field :: proc(v: any, info: reflect.Type_Info_Struct, i: int) -> bool {
	tag := parse_field_tag(info.names[i], info.tags[i])
	if tag.skip {
		return false
	}
	if tag.omit_empty {
		field := any{rawptr(uintptr(v.data) + info.offsets[i]), info.types[i].id}
		return !is_empty(field)
	}
	return true
}

// Field_Tag is the parsed form of a `msgpack:"name,omitempty"` struct tag.
@(private)
Field_Tag :: struct {
	name:       string,
	skip:       bool,
	omit_empty: bool,
}

@(private)
parse_field_tag :: proc(field_name: string, raw_tag: string) -> (tag: Field_Tag) {
	value, found := reflect.struct_tag_lookup(reflect.Struct_Tag(raw_tag), "msgpack")
	tag.name = field_name
	if !found {
		return
	}
	if value == "-" {
		tag.skip = true
		return
	}
	rest := string(value)
	name, _, opts := strings.partition(rest, ",")
	if name != "" {
		tag.name = name
	}
	for opt in strings.split_iterator(&opts, ",") {
		if strings.trim_space(opt) == "omitempty" {
			tag.omit_empty = true
		}
	}
	return
}

// is_empty reports whether a field counts as empty for `omitempty`.
@(private)
is_empty :: proc(v: any) -> bool {
	ti := reflect.type_info_base(type_info_of(v.id))
	#partial switch info in ti.variant {
	case reflect.Type_Info_String:
		if info.is_cstring {
			cs := (^cstring)(v.data)^
			return cs == nil || len(cs) == 0
		}
		return len((^string)(v.data)^) == 0
	case reflect.Type_Info_Slice:
		return (^runtime.Raw_Slice)(v.data).len == 0
	case reflect.Type_Info_Dynamic_Array:
		return (^runtime.Raw_Dynamic_Array)(v.data).len == 0
	case reflect.Type_Info_Map:
		return (^runtime.Raw_Map)(v.data).len == 0
	}
	bytes := ([^]byte)(v.data)[:ti.size]
	for b in bytes {
		if b != 0 {
			return false
		}
	}
	return true
}

@(private)
is_byte_type :: proc(ti: ^reflect.Type_Info) -> bool {
	base := reflect.type_info_base(ti)
	return base.id == u8
}

@(private)
write_i128 :: proc(e: ^Encoder, x: i128) -> Error {
	switch {
	case x < i128(min(i64)) || x > i128(max(u64)):
		return Encode_Error.Integer_Out_Of_Range
	case x < 0:
		return write_int(e, i64(x))
	case:
		return write_uint(e, u64(x))
	}
}

// any_to_i128 reads an integer of any width and endianness.
@(private)
any_to_i128 :: proc(v: any) -> (x: i128, ok: bool) {
	switch n in reflect.any_core(v) {
	case i8:
		return i128(n), true
	case i16:
		return i128(n), true
	case i32:
		return i128(n), true
	case i64:
		return i128(n), true
	case i128:
		return n, true
	case int:
		return i128(n), true
	case u8:
		return i128(n), true
	case u16:
		return i128(n), true
	case u32:
		return i128(n), true
	case u64:
		return i128(n), true
	case u128:
		if n > u128(max(i128)) {
			return 0, false
		}
		return i128(n), true
	case uint:
		return i128(n), true
	case uintptr:
		return i128(n), true
	case rune:
		return i128(n), true
	case i16le:
		return i128(n), true
	case i32le:
		return i128(n), true
	case i64le:
		return i128(n), true
	case i128le:
		return i128(n), true
	case u16le:
		return i128(n), true
	case u32le:
		return i128(n), true
	case u64le:
		return i128(n), true
	case u128le:
		if n > u128le(max(i128)) {
			return 0, false
		}
		return i128(n), true
	case i16be:
		return i128(n), true
	case i32be:
		return i128(n), true
	case i64be:
		return i128(n), true
	case i128be:
		return i128(n), true
	case u16be:
		return i128(n), true
	case u32be:
		return i128(n), true
	case u64be:
		return i128(n), true
	case u128be:
		if n > u128be(max(i128)) {
			return 0, false
		}
		return i128(n), true
	}
	return 0, false
}

/*
timestamp_from_time converts a `time.Time` to a Timestamp. The nanosecond
part is always in `[0, 1e9)`, also for times before 1970.
*/
timestamp_from_time :: proc(t: time.Time) -> Timestamp {
	ns := time.to_unix_nanoseconds(t)
	seconds := ns / 1_000_000_000
	nanos := ns % 1_000_000_000
	if nanos < 0 {
		seconds -= 1
		nanos += 1_000_000_000
	}
	return Timestamp{seconds, u32(nanos)}
}

/*
timestamp_to_time converts a Timestamp to a `time.Time`. `ok` is false when
the timestamp lies outside the range that `time.Time` can hold, roughly the
years 1678 to 2262.
*/
timestamp_to_time :: proc(ts: Timestamp) -> (t: time.Time, ok: bool) {
	ns := i128(ts.seconds) * 1_000_000_000 + i128(ts.nanoseconds)
	if ns < i128(min(i64)) || ns > i128(max(i64)) {
		return {}, false
	}
	return time.from_nanoseconds(i64(ns)), true
}
