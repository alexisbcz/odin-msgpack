package msgpack

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:strings"
import "core:time"

/*
unmarshal decodes exactly one MessagePack item from `data` into `ptr^`.

It uses the same mapping as marshal and adds some leniency: integers decode
into floats, str and bin are interchangeable for strings and byte slices, a
str decodes into an enum by member name, and nil leaves the destination at its
zero value. Struct fields match by tag name, or by field name when the field
has no tag name; unknown keys are skipped. For a union other than Value, the
first variant of the item's own kind receives it; when no variant has that
kind, the first variant that one of the lenient conversions above reaches
receives it.

The destination is overwritten, not merged. Free any memory it held before
the call yourself. On failure `ptr^` is untouched and nothing leaks.

Inputs:
- data: the input; the result doesn't borrow from it.
- ptr: the destination.
- allocator: allocates every string, slice, map and pointer target in the result.
- max_depth: the deepest nesting of arrays, maps and pointers to accept.

Returns:
- err: a Decode_Error, `.Trailing_Data` when bytes follow the item, or an
  allocator error. Free a successful result with `destroy(ptr, allocator)`.
*/
unmarshal :: proc(data: []byte, ptr: ^$T, allocator := context.allocator, max_depth := DEFAULT_MAX_DEPTH) -> (err: Error) {
	d: Decoder
	decoder_init(&d, data, max_depth)
	if ptr == nil {
		return Decode_Error.Nil_Destination
	}
	tmp: T
	err = unmarshal_any(&d, any{&tmp, typeid_of(T)}, allocator)
	if err == nil && decoder_remaining(&d) != 0 {
		err = Decode_Error.Trailing_Data
	}
	if err != nil {
		destroy(&tmp, allocator)
		return err
	}
	ptr^ = tmp
	return nil
}

/*
read_into consumes the next item from `d` into `ptr^`, with the same rules as
unmarshal. Unlike unmarshal, it leaves any following bytes for later reads.
On failure `ptr^` is untouched, nothing leaks and the decoder doesn't move.
*/
read_into :: proc(d: ^Decoder, ptr: ^$T, allocator := context.allocator) -> (err: Error) {
	if ptr == nil {
		return Decode_Error.Nil_Destination
	}
	start := d.pos
	tmp: T
	if err = unmarshal_any(d, any{&tmp, typeid_of(T)}, allocator); err != nil {
		destroy(&tmp, allocator)
		d.pos = start
		return err
	}
	ptr^ = tmp
	return nil
}

/*
destroy frees everything that unmarshal or read_into allocated inside
`ptr^` and then zeroes it: strings, slices, dynamic arrays, maps, pointer
targets, Value and Extension data, recursively. Pass the allocator used to
decode. Fields tagged `msgpack:"-"` are left alone, because unmarshal never
writes them.
*/
destroy :: proc(ptr: ^$T, allocator := context.allocator) {
	if ptr == nil {
		return
	}
	destroy_any(any{ptr, typeid_of(T)}, allocator)
	ptr^ = {}
}

// unmarshal_any decodes into `v`, which must point at zeroed memory.
@(private)
unmarshal_any :: proc(d: ^Decoder, v: any, allocator: runtime.Allocator) -> (err: Error) {
	enter(d) or_return
	defer d.depth -= 1

	switch v.id {
	case Value:
		(^Value)(v.data)^ = read_value(d, allocator) or_return
		return nil
	case Timestamp:
		if read_nil(d) == nil {
			return nil
		}
		(^Timestamp)(v.data)^ = read_timestamp(d) or_return
		return nil
	case time.Time:
		if read_nil(d) == nil {
			return nil
		}
		ts := read_timestamp(d) or_return
		t, ok := timestamp_to_time(ts)
		if !ok {
			return Decode_Error.Invalid_Timestamp
		}
		(^time.Time)(v.data)^ = t
		return nil
	case Extension:
		if read_nil(d) == nil {
			return nil
		}
		type, data := read_ext(d) or_return
		(^Extension)(v.data)^ = Extension{type, clone_bytes(data, allocator) or_return}
		return nil
	case Map, Array:
		value := read_value(d, allocator) or_return
		switch x in value {
		case nil:
			return nil
		case Map:
			if v.id == Map {
				(^Map)(v.data)^ = x
				return nil
			}
		case Array:
			if v.id == Array {
				(^Array)(v.data)^ = x
				return nil
			}
		case bool, i64, u64, f32, f64, string, Binary, Extension, Timestamp:
		}
		value_destroy(value, allocator)
		return Decode_Error.Type_Mismatch
	}

	kind := peek_kind(d) or_return
	if kind == .Nil {
		d.pos += 1
		return nil
	}

	ti := reflect.type_info_base(type_info_of(v.id))
	#partial switch info in ti.variant {
	case reflect.Type_Info_Integer, reflect.Type_Info_Rune:
		return unmarshal_int(d, v)

	case reflect.Type_Info_Enum:
		if kind == .String {
			name := read_str(d) or_return
			for member, i in info.names {
				if member == name {
					if !assign_int(any{v.data, info.base.id}, i128(info.values[i])) {
						return Decode_Error.Integer_Overflow
					}
					return nil
				}
			}
			return Decode_Error.Type_Mismatch
		}
		return unmarshal_int(d, any{v.data, info.base.id})

	case reflect.Type_Info_Float:
		f := read_float(d) or_return
		if !assign_float(v, f) {
			return Decode_Error.Unsupported_Destination
		}
		return nil

	case reflect.Type_Info_Boolean:
		b := read_bool(d) or_return
		if !assign_bool(v, b) {
			return Decode_Error.Unsupported_Destination
		}
		return nil

	case reflect.Type_Info_String:
		if info.encoding != .UTF_8 {
			return Decode_Error.Unsupported_Destination
		}
		text := read_text(d, kind) or_return
		if info.is_cstring {
			(^cstring)(v.data)^ = strings.clone_to_cstring(text, allocator) or_return
		} else if len(text) > 0 {
			(^string)(v.data)^ = strings.clone(text, allocator) or_return
		}
		return nil

	case reflect.Type_Info_Pointer:
		if info.elem == nil {
			return Decode_Error.Unsupported_Destination
		}
		target := mem.alloc(info.elem.size, info.elem.align, allocator) or_return
		(^rawptr)(v.data)^ = target
		return unmarshal_any(d, any{target, info.elem.id}, allocator)

	case reflect.Type_Info_Slice:
		n := sequence_length(d, kind, info.elem) or_return
		data := alloc_elements(n, info.elem, allocator) or_return
		raw := (^runtime.Raw_Slice)(v.data)
		raw^ = {data, n}
		return unmarshal_elements(d, kind, data, n, info.elem, allocator)

	case reflect.Type_Info_Dynamic_Array:
		n := sequence_length(d, kind, info.elem) or_return
		data := alloc_elements(n, info.elem, allocator) or_return
		raw := (^runtime.Raw_Dynamic_Array)(v.data)
		raw^ = {data, n, n, allocator}
		return unmarshal_elements(d, kind, data, n, info.elem, allocator)

	case reflect.Type_Info_Array:
		n := sequence_length(d, kind, info.elem) or_return
		if n > info.count {
			return Decode_Error.Too_Many_Elements
		}
		return unmarshal_elements(d, kind, v.data, n, info.elem, allocator)

	case reflect.Type_Info_Enumerated_Array:
		if kind != .Array {
			return Decode_Error.Type_Mismatch
		}
		n := read_array_header(d) or_return
		if n > info.count {
			return Decode_Error.Too_Many_Elements
		}
		for i in 0 ..< n {
			elem := rawptr(uintptr(v.data) + uintptr(i * info.elem_size))
			unmarshal_any(d, any{elem, info.elem.id}, allocator) or_return
		}
		return nil

	case reflect.Type_Info_Map:
		return unmarshal_map(d, v, info, allocator)

	case reflect.Type_Info_Struct:
		return unmarshal_struct(d, v, info, allocator)

	case reflect.Type_Info_Union:
		// Prefer a variant of the item's own kind, then fall back to the lenient conversions.
		for exact in ([2]bool{true, false}) {
			for variant in info.variants {
				if kind_fits(kind, variant, exact) {
					reflect.set_union_variant_typeid(v, variant.id)
					return unmarshal_any(d, any{v.data, variant.id}, allocator)
				}
			}
		}
		return Decode_Error.Type_Mismatch
	}
	return Decode_Error.Unsupported_Destination
}

@(private)
unmarshal_int :: proc(d: ^Decoder, v: any) -> Error {
	start := d.pos
	x := read_integer(d) or_return
	if !assign_int(v, x) {
		d.pos = start
		return Decode_Error.Integer_Overflow
	}
	return nil
}

// read_text reads a str or a bin item as text.
@(private)
read_text :: proc(d: ^Decoder, kind: Kind) -> (text: string, err: Error) {
	if kind == .Binary {
		b := read_bin(d) or_return
		return string(b), nil
	}
	return read_str(d)
}

// sequence_length reads the header of an array, or of a str or bin when the elements are bytes.
@(private)
sequence_length :: proc(d: ^Decoder, kind: Kind, elem: ^reflect.Type_Info) -> (n: int, err: Error) {
	if kind == .Array {
		return read_array_header(d)
	}
	if (kind == .Binary || kind == .String) && is_byte_type(elem) {
		start := d.pos
		text := read_text(d, kind) or_return
		d.pos = start
		return len(text), nil
	}
	return 0, Decode_Error.Type_Mismatch
}

// unmarshal_elements fills `n` elements at `data`, from an array or from the bytes of a str or bin.
@(private)
unmarshal_elements :: proc(d: ^Decoder, kind: Kind, data: rawptr, n: int, elem: ^reflect.Type_Info, allocator: runtime.Allocator) -> Error {
	if kind != .Array {
		text := read_text(d, kind) or_return
		copy(([^]byte)(data)[:n], text)
		return nil
	}
	for i in 0 ..< n {
		item := rawptr(uintptr(data) + uintptr(i * elem.size))
		unmarshal_any(d, any{item, elem.id}, allocator) or_return
	}
	return nil
}

@(private)
alloc_elements :: proc(n: int, elem: ^reflect.Type_Info, allocator: runtime.Allocator) -> (data: rawptr, err: Error) {
	if n == 0 {
		return nil, nil
	}
	return mem.alloc(n * elem.size, elem.align, allocator)
}

@(private)
unmarshal_map :: proc(d: ^Decoder, v: any, info: reflect.Type_Info_Map, allocator: runtime.Allocator) -> (err: Error) {
	n := read_map_header(d) or_return
	raw := (^runtime.Raw_Map)(v.data)
	raw.allocator = allocator
	if n == 0 {
		return nil
	}
	runtime.map_reserve_dynamic(raw, info.map_info, uintptr(n)) or_return

	// Scratch space for one key and one value. It comes from the caller's
	// allocator, so decoding never touches context.temp_allocator.
	key_buf := mem.alloc_bytes(info.key.size, info.key.align, allocator) or_return
	defer mem.free_bytes(key_buf, allocator)
	value_buf := mem.alloc_bytes(info.value.size, info.value.align, allocator) or_return
	defer mem.free_bytes(value_buf, allocator)

	key := any{raw_data(key_buf), info.key.id}
	value := any{raw_data(value_buf), info.value.id}

	for _ in 0 ..< n {
		mem.zero_slice(key_buf)
		mem.zero_slice(value_buf)
		err = unmarshal_any(d, key, allocator)
		if err == nil {
			err = unmarshal_any(d, value, allocator)
		}
		if err == nil {
			hash := info.map_info.key_hasher(key.data, runtime.map_seed(raw^))
			if runtime.__dynamic_map_get(raw, info.map_info, hash, key.data) != nil {
				err = Decode_Error.Duplicate_Key
			} else {
				_, err = runtime.__dynamic_map_set(raw, info.map_info, hash, key.data, value.data)
			}
		}
		if err != nil {
			destroy_any(key, allocator)
			destroy_any(value, allocator)
			return err
		}
	}
	return nil
}

@(private)
unmarshal_struct :: proc(d: ^Decoder, v: any, info: reflect.Type_Info_Struct, allocator: runtime.Allocator) -> Error {
	if .raw_union in info.flags {
		return Decode_Error.Unsupported_Destination
	}
	n := read_map_header(d) or_return
	for _ in 0 ..< n {
		key: string
		switch peek_kind(d) or_return {
		case .String:
			key = read_str(d) or_return
		case .Binary:
			key = string(read_bin(d) or_return)
		case .Nil, .Bool, .Int, .Float, .Array, .Map, .Extension, .Timestamp:
			// A key that can't name a field: skip the pair.
			skip(d) or_return
			skip(d) or_return
			continue
		}

		index := find_field(info, key)
		if index < 0 {
			skip(d) or_return
			continue
		}
		field := any{rawptr(uintptr(v.data) + info.offsets[index]), info.types[index].id}
		// A repeated key replaces the earlier value; free that one first.
		destroy_any(field, allocator)
		mem.zero(field.data, info.types[index].size)
		unmarshal_any(d, field, allocator) or_return
	}
	return nil
}

@(private)
find_field :: proc(info: reflect.Type_Info_Struct, key: string) -> int {
	for i in 0 ..< int(info.field_count) {
		tag := parse_field_tag(info.names[i], info.tags[i])
		if !tag.skip && tag.name == key {
			return i
		}
	}
	return -1
}

/*
kind_fits reports whether an item of `kind` can decode into a union variant
of type `ti`. With `exact`, only the variant's own MessagePack kind fits.
Without it, the lenient conversions that unmarshal applies to plain
destinations also fit: integers into floats, str and bin into each other for
text and bytes, and str into enums.
*/
@(private)
kind_fits :: proc(kind: Kind, ti: ^reflect.Type_Info, exact: bool) -> bool {
	switch ti.id {
	case Value:
		return true
	case Timestamp, time.Time:
		return kind == .Timestamp
	case Extension:
		return kind == .Extension || (!exact && kind == .Timestamp)
	case Map:
		return kind == .Map
	case Array:
		return kind == .Array
	}
	base := reflect.type_info_base(ti)
	#partial switch info in base.variant {
	case reflect.Type_Info_Boolean:
		return kind == .Bool
	case reflect.Type_Info_Integer, reflect.Type_Info_Rune:
		return kind == .Int
	case reflect.Type_Info_Enum:
		return kind == .Int || (!exact && kind == .String)
	case reflect.Type_Info_Float:
		return kind == .Float || (!exact && kind == .Int)
	case reflect.Type_Info_String:
		return info.encoding == .UTF_8 && (kind == .String || (!exact && kind == .Binary))
	case reflect.Type_Info_Slice:
		return sequence_fits(kind, info.elem, exact)
	case reflect.Type_Info_Dynamic_Array:
		return sequence_fits(kind, info.elem, exact)
	case reflect.Type_Info_Array:
		return sequence_fits(kind, info.elem, exact)
	case reflect.Type_Info_Enumerated_Array:
		return kind == .Array
	case reflect.Type_Info_Map, reflect.Type_Info_Struct:
		return kind == .Map
	case reflect.Type_Info_Pointer:
		return info.elem != nil && kind_fits(kind, info.elem, exact)
	case reflect.Type_Info_Union:
		for variant in info.variants {
			if kind_fits(kind, variant, exact) {
				return true
			}
		}
	}
	return false
}

// sequence_fits reports whether an item of `kind` can fill a slice or array of `elem`.
@(private)
sequence_fits :: proc(kind: Kind, elem: ^reflect.Type_Info, exact: bool) -> bool {
	if kind == .Array {
		return true
	}
	if !is_byte_type(elem) {
		return false
	}
	return kind == .Binary || (!exact && kind == .String)
}

@(private)
assign_int :: proc(v: any, x: i128) -> bool {
	store :: proc(p: rawptr, $T: typeid, x: i128) -> bool {
		when T == u128 || T == u128le || T == u128be {
			if x < 0 {
				return false
			}
		} else when T != i128 && T != i128le && T != i128be {
			if x < i128(min(T)) || x > i128(max(T)) {
				return false
			}
		}
		(^T)(p)^ = T(x)
		return true
	}

	p := v.data
	switch reflect.any_core(v).id {
	case i8:
		return store(p, i8, x)
	case i16:
		return store(p, i16, x)
	case i32:
		return store(p, i32, x)
	case i64:
		return store(p, i64, x)
	case i128:
		return store(p, i128, x)
	case int:
		return store(p, int, x)
	case u8:
		return store(p, u8, x)
	case u16:
		return store(p, u16, x)
	case u32:
		return store(p, u32, x)
	case u64:
		return store(p, u64, x)
	case u128:
		return store(p, u128, x)
	case uint:
		return store(p, uint, x)
	case uintptr:
		return store(p, uintptr, x)
	case rune:
		return store(p, rune, x)
	case i16le:
		return store(p, i16le, x)
	case i32le:
		return store(p, i32le, x)
	case i64le:
		return store(p, i64le, x)
	case i128le:
		return store(p, i128le, x)
	case u16le:
		return store(p, u16le, x)
	case u32le:
		return store(p, u32le, x)
	case u64le:
		return store(p, u64le, x)
	case u128le:
		return store(p, u128le, x)
	case i16be:
		return store(p, i16be, x)
	case i32be:
		return store(p, i32be, x)
	case i64be:
		return store(p, i64be, x)
	case i128be:
		return store(p, i128be, x)
	case u16be:
		return store(p, u16be, x)
	case u32be:
		return store(p, u32be, x)
	case u64be:
		return store(p, u64be, x)
	case u128be:
		return store(p, u128be, x)
	}
	return false
}

@(private)
assign_float :: proc(v: any, f: f64) -> bool {
	switch &dst in reflect.any_core(v) {
	case f16:
		dst = f16(f)
	case f16le:
		dst = f16le(f)
	case f16be:
		dst = f16be(f)
	case f32:
		dst = f32(f)
	case f32le:
		dst = f32le(f)
	case f32be:
		dst = f32be(f)
	case f64:
		dst = f
	case f64le:
		dst = f64le(f)
	case f64be:
		dst = f64be(f)
	case:
		return false
	}
	return true
}

@(private)
assign_bool :: proc(v: any, b: bool) -> bool {
	switch &dst in reflect.any_core(v) {
	case bool:
		dst = b
	case b8:
		dst = b8(b)
	case b16:
		dst = b16(b)
	case b32:
		dst = b32(b)
	case b64:
		dst = b64(b)
	case:
		return false
	}
	return true
}

// destroy_any frees what unmarshal_any allocated inside `v`. Zeroed memory is safe to pass.
@(private)
destroy_any :: proc(v: any, allocator: runtime.Allocator) {
	if v.data == nil || v.id == nil {
		return
	}
	switch v.id {
	case Value:
		value_destroy((^Value)(v.data)^, allocator)
		return
	case Map:
		value_destroy((^Map)(v.data)^, allocator)
		return
	case Array:
		value_destroy((^Array)(v.data)^, allocator)
		return
	case Extension:
		delete((^Extension)(v.data).data, allocator)
		return
	case Timestamp, time.Time:
		return
	}

	ti := reflect.type_info_base(type_info_of(v.id))
	#partial switch info in ti.variant {
	case reflect.Type_Info_String:
		if info.encoding != .UTF_8 {
			return
		}
		if info.is_cstring {
			cs := (^cstring)(v.data)^
			if cs != nil {
				delete(cs, allocator)
			}
		} else {
			delete((^string)(v.data)^, allocator)
		}

	case reflect.Type_Info_Pointer:
		target := (^rawptr)(v.data)^
		if target != nil && info.elem != nil {
			destroy_any(any{target, info.elem.id}, allocator)
			mem.free(target, allocator)
		}

	case reflect.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(v.data)
		destroy_elements(raw.data, raw.len, info.elem, allocator)
		mem.free(raw.data, allocator)

	case reflect.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(v.data)
		destroy_elements(raw.data, raw.len, info.elem, allocator)
		if raw.data != nil {
			mem.free(raw.data, raw.allocator)
		}

	case reflect.Type_Info_Array:
		destroy_elements(v.data, info.count, info.elem, allocator)

	case reflect.Type_Info_Enumerated_Array:
		destroy_elements(v.data, info.count, info.elem, allocator)

	case reflect.Type_Info_Map:
		if info.map_info == nil {
			return
		}
		raw := (^runtime.Raw_Map)(v.data)
		if raw.data == 0 {
			return
		}
		if needs_destroy(info.key) || needs_destroy(info.value) {
			it: int
			for key, value in reflect.iterate_map(v, &it) {
				destroy_any(key, allocator)
				destroy_any(value, allocator)
			}
		}
		_ = runtime.map_free_dynamic(raw^, info.map_info)

	case reflect.Type_Info_Struct:
		if .raw_union in info.flags {
			return
		}
		for i in 0 ..< int(info.field_count) {
			if parse_field_tag(info.names[i], info.tags[i]).skip {
				continue
			}
			field := any{rawptr(uintptr(v.data) + info.offsets[i]), info.types[i].id}
			destroy_any(field, allocator)
		}

	case reflect.Type_Info_Union:
		destroy_any(reflect.get_union_variant(v), allocator)
	}
}

@(private)
destroy_elements :: proc(data: rawptr, n: int, elem: ^reflect.Type_Info, allocator: runtime.Allocator) {
	if data == nil || !needs_destroy(elem) {
		return
	}
	for i in 0 ..< n {
		destroy_any(any{rawptr(uintptr(data) + uintptr(i * elem.size)), elem.id}, allocator)
	}
}

// needs_destroy reports whether values of type `ti` can own memory.
@(private)
needs_destroy :: proc(ti: ^reflect.Type_Info) -> bool {
	switch ti.id {
	case Timestamp, time.Time:
		return false
	}
	base := reflect.type_info_base(ti)
	#partial switch info in base.variant {
	case reflect.Type_Info_Integer, reflect.Type_Info_Rune, reflect.Type_Info_Float, reflect.Type_Info_Boolean, reflect.Type_Info_Enum:
		return false
	case reflect.Type_Info_Array:
		return needs_destroy(info.elem)
	}
	return true
}
