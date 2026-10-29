package msgpack_tests

import msgpack ".."
import "core:mem"
import "core:testing"
import "core:time"

Color :: enum u8 {
	Red,
	Green,
	Blue,
}

Address :: struct {
	city: string,
	zip:  u32,
}

User :: struct {
	id:       u64,
	name:     string `msgpack:"username"`,
	email:    string `msgpack:",omitempty"`,
	password: string `msgpack:"-"`,
	score:    f64,
	active:   bool,
	tags:     []string,
	color:    Color,
	address:  Address,
	manager:  ^Address,
	extra:    map[string]int,
	avatar:   []byte,
	joined:   msgpack.Timestamp,
}

@(test)
test_marshal_struct_round_trip :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	boss := Address{"Paris", 75001}
	extra := make(map[string]int, alloc)
	defer delete(extra)
	extra["level"] = 3
	tags := []string{"admin", "ops"}
	avatar := []byte{1, 2, 3}

	in_user := User {
		id       = 42,
		name     = "ada",
		password = "secret",
		score    = 9.5,
		active   = true,
		tags     = tags,
		color    = .Blue,
		address  = {"Lyon", 69001},
		manager  = &boss,
		extra    = extra,
		avatar   = avatar,
		joined   = {seconds = 1_700_000_000, nanoseconds = 5},
	}
	data, err := msgpack.marshal(in_user, alloc)
	defer delete(data, alloc)
	testing.expect_value(t, err, nil)

	out: User
	testing.expect_value(t, msgpack.unmarshal(data, &out, alloc), nil)
	defer msgpack.destroy(&out, alloc)

	testing.expect_value(t, out.id, 42)
	testing.expect_value(t, out.name, "ada")
	testing.expect_value(t, out.email, "")
	testing.expect_value(t, out.password, "")
	testing.expect_value(t, out.score, 9.5)
	testing.expect_value(t, out.active, true)
	testing.expect_value(t, len(out.tags), 2)
	testing.expect_value(t, out.tags[1], "ops")
	testing.expect_value(t, out.color, Color.Blue)
	testing.expect_value(t, out.address, Address{"Lyon", 69001})
	testing.expect(t, out.manager != nil && out.manager.city == "Paris")
	testing.expect_value(t, out.extra["level"], 3)
	testing.expect_value(t, len(out.avatar), 3)
	testing.expect_value(t, out.joined, in_user.joined)
}

@(test)
test_marshal_struct_uses_tag_names_and_skips :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Small :: struct {
		a:      int `msgpack:"A"`,
		hidden: int `msgpack:"-"`,
		empty:  string `msgpack:"e,omitempty"`,
	}
	data, err := msgpack.marshal(Small{a = 1, hidden = 2}, alloc)
	defer delete(data, alloc)
	testing.expect_value(t, err, nil)
	expect_bytes(t, data, {0x81, 0xa1, 'A', 0x01})
}

@(test)
test_marshal_omitempty_keeps_non_zero_fields :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Opt :: struct {
		n: int `msgpack:"n,omitempty"`,
		s: []int `msgpack:"s,omitempty"`,
	}
	data, err := msgpack.marshal(Opt{n = 7}, alloc)
	defer delete(data, alloc)
	testing.expect_value(t, err, nil)
	expect_bytes(t, data, {0x81, 0xa1, 'n', 0x07})
}

@(test)
test_marshal_scalars_match_spec_bytes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Case :: struct {
		value: any,
		want:  []byte,
	}
	i: i16 = -200
	u: u8 = 200
	be: u32be = 70000
	f: f32 = 1.5
	h: f16 = 1.5
	r: rune = 'A'
	b: b8 = true
	s := "hi"
	cs: cstring = "c"
	color := Color.Green
	cases := []Case {
		{i, {0xd1, 0xff, 0x38}},
		{u, {0xcc, 0xc8}},
		{be, {0xce, 0x00, 0x01, 0x11, 0x70}},
		{f, {0xca, 0x3f, 0xc0, 0x00, 0x00}},
		{h, {0xca, 0x3f, 0xc0, 0x00, 0x00}},
		{r, {0x41}},
		{b, {0xc3}},
		{s, {0xa2, 'h', 'i'}},
		{cs, {0xa1, 'c'}},
		{color, {0x01}},
	}
	for c in cases {
		data, err := msgpack.marshal(c.value, alloc)
		testing.expect_value(t, err, nil)
		expect_bytes(t, data, c.want)
		delete(data, alloc)
	}
}

@(test)
test_marshal_byte_containers_become_bin :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	fixed := [3]byte{1, 2, 3}
	dyn := make([dynamic]byte, 0, 2, alloc)
	defer delete(dyn)
	append(&dyn, 9)

	a, _ := msgpack.marshal(fixed, alloc)
	defer delete(a, alloc)
	expect_bytes(t, a, {0xc4, 0x03, 1, 2, 3})

	b, _ := msgpack.marshal(dyn, alloc)
	defer delete(b, alloc)
	expect_bytes(t, b, {0xc4, 0x01, 9})
}

@(test)
test_marshal_arrays_and_enumerated_arrays :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	nums := [3]i32{1, -1, 300}
	data, _ := msgpack.marshal(nums, alloc)
	defer delete(data, alloc)
	expect_bytes(t, data, {0x93, 0x01, 0xff, 0xcd, 0x01, 0x2c})

	weights := [Color]u8 {
		.Red   = 1,
		.Green = 2,
		.Blue  = 3,
	}
	wdata, _ := msgpack.marshal(weights, alloc)
	defer delete(wdata, alloc)
	expect_bytes(t, wdata, {0x93, 1, 2, 3})

	back: [Color]u8
	testing.expect_value(t, msgpack.unmarshal(wdata, &back, alloc), nil)
	testing.expect_value(t, back[.Blue], 3)
}

@(test)
test_marshal_nil_pointer_and_union :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Holder :: struct {
		p: ^int,
		m: Maybe(int),
	}
	data, err := msgpack.marshal(Holder{}, alloc)
	defer delete(data, alloc)
	testing.expect_value(t, err, nil)
	expect_bytes(t, data, {0x82, 0xa1, 'p', 0xc0, 0xa1, 'm', 0xc0})

	n := 5
	data2, _ := msgpack.marshal(Holder{p = &n, m = 6}, alloc)
	defer delete(data2, alloc)
	expect_bytes(t, data2, {0x82, 0xa1, 'p', 0x05, 0xa1, 'm', 0x06})

	back: Holder
	testing.expect_value(t, msgpack.unmarshal(data2, &back, alloc), nil)
	defer msgpack.destroy(&back, alloc)
	testing.expect_value(t, back.p^, 5)
	testing.expect_value(t, back.m.? or_else 0, 6)
}

@(test)
test_marshal_rejects_unsupported_types :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Bad :: struct {
		ok: int,
		f:  proc(),
	}
	data, err := msgpack.marshal(Bad{ok = 1}, alloc)
	testing.expect_value(t, err, encode_err(.Unsupported_Type))
	testing.expect(t, data == nil)

	raw: rawptr
	_, rerr := msgpack.marshal(raw, alloc)
	testing.expect_value(t, rerr, encode_err(.Unsupported_Type))
}

@(test)
test_marshal_into_rolls_back_on_failure :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Bad :: struct {
		ok: int,
		f:  proc(),
	}
	e: msgpack.Encoder
	msgpack.encoder_init(&e, 0, alloc)
	defer msgpack.encoder_destroy(&e)
	msgpack.write_int(&e, 1)
	testing.expect_value(t, msgpack.marshal_into(&e, Bad{}), encode_err(.Unsupported_Type))
	expect_bytes(t, msgpack.encoder_bytes(&e), {0x01})
}

@(test)
test_marshal_detects_pointer_cycles :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Node :: struct {
		next: ^Node,
	}
	a: Node
	a.next = &a
	_, err := msgpack.marshal(a, alloc)
	testing.expect_value(t, err, encode_err(.Nesting_Too_Deep))
}

@(test)
test_marshal_integer_out_of_range :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	big: i128 = i128(max(u64)) + 1
	_, err := msgpack.marshal(big, alloc)
	testing.expect_value(t, err, encode_err(.Integer_Out_Of_Range))

	ok: u128 = u128(max(u64))
	data, okerr := msgpack.marshal(ok, alloc)
	defer delete(data, alloc)
	testing.expect_value(t, okerr, nil)
	testing.expect_value(t, len(data), 9)
}

@(test)
test_unmarshal_into_map_of_slices :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	// {"a": [1, 2], "b": []}
	input := []byte{0x82, 0xa1, 'a', 0x92, 0x01, 0x02, 0xa1, 'b', 0x90}
	m: map[string][dynamic]int
	testing.expect_value(t, msgpack.unmarshal(input, &m, alloc), nil)
	defer msgpack.destroy(&m, alloc)
	testing.expect_value(t, len(m), 2)
	testing.expect_value(t, len(m["a"]), 2)
	testing.expect_value(t, m["a"][1], 2)
	testing.expect_value(t, len(m["b"]), 0)
}

@(test)
test_unmarshal_map_with_integer_keys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	src := make(map[i32]string, alloc)
	defer delete(src)
	src[-7] = "minus seven"
	src[1000] = "thousand"
	data, err := msgpack.marshal(src, alloc)
	defer delete(data, alloc)
	testing.expect_value(t, err, nil)

	dst: map[i32]string
	testing.expect_value(t, msgpack.unmarshal(data, &dst, alloc), nil)
	defer msgpack.destroy(&dst, alloc)
	testing.expect_value(t, dst[-7], "minus seven")
	testing.expect_value(t, dst[1000], "thousand")
}

@(test)
test_unmarshal_rejects_duplicate_map_keys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	input := []byte{0x82, 0xa1, 'k', 0xa1, 'x', 0xa1, 'k', 0xa1, 'y'}
	m: map[string]string
	testing.expect_value(t, msgpack.unmarshal(input, &m, alloc), decode_err(.Duplicate_Key))
	testing.expect_value(t, len(m), 0)
}

@(test)
test_unmarshal_struct_duplicate_key_replaces_without_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	input := []byte{0x82, 0xa4, 'c', 'i', 't', 'y', 0xa1, 'x', 0xa4, 'c', 'i', 't', 'y', 0xa1, 'y'}
	a: Address
	testing.expect_value(t, msgpack.unmarshal(input, &a, alloc), nil)
	defer msgpack.destroy(&a, alloc)
	testing.expect_value(t, a.city, "y")
}

@(test)
test_unmarshal_skips_unknown_and_non_string_keys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	// {"zip": 5, "unknown": [1, {"x": 2}], 7: "seven", "city": "Nice"}
	input := []byte {
		0x84,
		0xa3, 'z', 'i', 'p', 0x05,
		0xa7, 'u', 'n', 'k', 'n', 'o', 'w', 'n', 0x92, 0x01, 0x81, 0xa1, 'x', 0x02,
		0x07, 0xa5, 's', 'e', 'v', 'e', 'n',
		0xa4, 'c', 'i', 't', 'y', 0xa4, 'N', 'i', 'c', 'e',
	}
	a: Address
	testing.expect_value(t, msgpack.unmarshal(input, &a, alloc), nil)
	defer msgpack.destroy(&a, alloc)
	testing.expect_value(t, a, Address{"Nice", 5})
}

@(test)
test_unmarshal_integer_overflow :: proc(t: ^testing.T) {
	x: u8
	testing.expect_value(t, msgpack.unmarshal([]byte{0xcd, 0x01, 0x00}, &x), decode_err(.Integer_Overflow))
	testing.expect_value(t, x, 0)

	y: i8
	testing.expect_value(t, msgpack.unmarshal([]byte{0xd1, 0xff, 0x7f}, &y), decode_err(.Integer_Overflow))
	z: u32
	testing.expect_value(t, msgpack.unmarshal([]byte{0xff}, &z), decode_err(.Integer_Overflow))
	w: i16be
	testing.expect_value(t, msgpack.unmarshal([]byte{0xd1, 0x80, 0x00}, &w), nil)
	testing.expect_value(t, w, -32768)
}

@(test)
test_unmarshal_type_mismatch :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	n: int
	testing.expect_value(t, msgpack.unmarshal([]byte{0xa1, 'x'}, &n, alloc), decode_err(.Type_Mismatch))
	b: bool
	testing.expect_value(t, msgpack.unmarshal([]byte{0x01}, &b, alloc), decode_err(.Type_Mismatch))
	s: string
	testing.expect_value(t, msgpack.unmarshal([]byte{0x90}, &s, alloc), decode_err(.Type_Mismatch))
	a: Address
	testing.expect_value(t, msgpack.unmarshal([]byte{0x90}, &a, alloc), decode_err(.Type_Mismatch))
}

@(test)
test_unmarshal_failure_leaves_destination_and_frees :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	// A valid "tags" array, then "id" carries a string, which fails.
	input := []byte{0x82, 0xa4, 't', 'a', 'g', 's', 0x92, 0xa1, 'a', 0xa1, 'b', 0xa2, 'i', 'd', 0xa1, 'x'}
	u := User {
		id = 99,
	}
	err := msgpack.unmarshal(input, &u, alloc)
	testing.expect_value(t, err, decode_err(.Type_Mismatch))
	testing.expect_value(t, u.id, 99)
	testing.expect(t, u.tags == nil)
}

@(test)
test_unmarshal_truncated_struct_does_not_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	full, _ := msgpack.marshal(User{name = "grace", tags = {"x", "y", "z"}, extra = nil}, alloc)
	defer delete(full, alloc)
	for cut in 0 ..< len(full) {
		u: User
		err := msgpack.unmarshal(full[:cut], &u, alloc)
		testing.expectf(t, err != nil, "cut at %d must fail", cut)
	}
}

@(test)
test_unmarshal_rejects_trailing_data :: proc(t: ^testing.T) {
	n: int
	testing.expect_value(t, msgpack.unmarshal([]byte{0x01, 0x02}, &n), decode_err(.Trailing_Data))
	testing.expect_value(t, n, 0)
}

@(test)
test_unmarshal_nil_destination :: proc(t: ^testing.T) {
	p: ^int
	testing.expect_value(t, msgpack.unmarshal([]byte{0x01}, p), decode_err(.Nil_Destination))
}

@(test)
test_unmarshal_nil_leaves_zero_value :: proc(t: ^testing.T) {
	Opt :: struct {
		name: string,
		ptr:  ^int,
		list: []int,
	}
	o: Opt
	testing.expect_value(t, msgpack.unmarshal([]byte{0x83, 0xa4, 'n', 'a', 'm', 'e', 0xc0, 0xa3, 'p', 't', 'r', 0xc0, 0xa4, 'l', 'i', 's', 't', 0xc0}, &o), nil)
	testing.expect_value(t, o.name, "")
	testing.expect(t, o.ptr == nil && o.list == nil)
}

@(test)
test_unmarshal_lenient_conversions :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	f: f32
	testing.expect_value(t, msgpack.unmarshal([]byte{0xd0, 0xfe}, &f, alloc), nil)
	testing.expect_value(t, f, -2)

	s: string
	testing.expect_value(t, msgpack.unmarshal([]byte{0xc4, 0x02, 'o', 'k'}, &s, alloc), nil)
	defer delete(s, alloc)
	testing.expect_value(t, s, "ok")

	b: []byte
	testing.expect_value(t, msgpack.unmarshal([]byte{0xa2, 'h', 'i'}, &b, alloc), nil)
	defer delete(b, alloc)
	testing.expect_value(t, string(b), "hi")

	c: Color
	testing.expect_value(t, msgpack.unmarshal([]byte{0xa4, 'B', 'l', 'u', 'e'}, &c, alloc), nil)
	testing.expect_value(t, c, Color.Blue)
	testing.expect_value(t, msgpack.unmarshal([]byte{0xa4, 'P', 'i', 'n', 'k'}, &c, alloc), decode_err(.Type_Mismatch))
}

@(test)
test_unmarshal_fixed_array_too_many_elements :: proc(t: ^testing.T) {
	arr: [2]int
	testing.expect_value(t, msgpack.unmarshal([]byte{0x93, 1, 2, 3}, &arr), decode_err(.Too_Many_Elements))
	ok: [4]int
	testing.expect_value(t, msgpack.unmarshal([]byte{0x92, 1, 2}, &ok), nil)
	testing.expect_value(t, ok, [4]int{1, 2, 0, 0})
	id: [4]byte
	testing.expect_value(t, msgpack.unmarshal([]byte{0xc4, 0x05, 1, 2, 3, 4, 5}, &id), decode_err(.Too_Many_Elements))
}

@(test)
test_unmarshal_union_picks_variant_by_kind :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Scalar :: union {
		i64,
		string,
		[]f64,
	}
	inputs := [][]byte{{0x2a}, {0xa2, 'h', 'i'}, {0x91, 0xcb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0}}
	for input, i in inputs {
		s: Scalar
		testing.expect_value(t, msgpack.unmarshal(input, &s, alloc), nil)
		switch v in s {
		case i64:
			testing.expect_value(t, i, 0)
			testing.expect_value(t, v, 42)
		case string:
			testing.expect_value(t, i, 1)
			testing.expect_value(t, v, "hi")
		case []f64:
			testing.expect_value(t, i, 2)
			testing.expect_value(t, v[0], 1.5)
		case:
			testing.expect(t, false, "union must not stay nil")
		}
		msgpack.destroy(&s, alloc)
	}
	s: Scalar
	testing.expect_value(t, msgpack.unmarshal([]byte{0xc3}, &s, alloc), decode_err(.Type_Mismatch))
}

@(test)
test_unmarshal_value_field_and_extension :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Envelope :: struct {
		kind:    string,
		payload: msgpack.Value,
		blob:    msgpack.Extension,
	}
	payload := []msgpack.Value{i64(1), "two"}
	in_env := Envelope {
		kind    = "list",
		payload = msgpack.Array(payload),
		blob    = {type = 9, data = {0xde, 0xad}},
	}
	data, err := msgpack.marshal(in_env, alloc)
	defer delete(data, alloc)
	testing.expect_value(t, err, nil)

	out: Envelope
	testing.expect_value(t, msgpack.unmarshal(data, &out, alloc), nil)
	defer msgpack.destroy(&out, alloc)
	testing.expect_value(t, out.kind, "list")
	arr := out.payload.(msgpack.Array)
	testing.expect_value(t, arr[1].(string), "two")
	testing.expect_value(t, out.blob.type, 9)
	testing.expect_value(t, out.blob.data[1], 0xad)
}

@(test)
test_time_round_trips_through_timestamp :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	when_ := time.unix(1_700_000_000, 123_456_789)
	data, err := msgpack.marshal(when_, alloc)
	defer delete(data, alloc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, data[0], 0xd7)

	back: time.Time
	testing.expect_value(t, msgpack.unmarshal(data, &back, alloc), nil)
	testing.expect_value(t, time.to_unix_nanoseconds(back), time.to_unix_nanoseconds(when_))

	before := time.unix(-1, 500)
	ts := msgpack.timestamp_from_time(before)
	testing.expect_value(t, ts, msgpack.Timestamp{-1, 500})

	_, ok := msgpack.timestamp_to_time({seconds = max(i64), nanoseconds = 0})
	testing.expect(t, !ok, "far future must not fit in time.Time")
}

@(test)
test_read_into_streams_typed_values :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	d: msgpack.Decoder
	msgpack.decoder_init(&d, {0x92, 0x01, 0x02, 0xa1, 'z'})
	nums: []int
	testing.expect_value(t, msgpack.read_into(&d, &nums, alloc), nil)
	defer delete(nums, alloc)
	s: string
	testing.expect_value(t, msgpack.read_into(&d, &s, alloc), nil)
	defer delete(s, alloc)
	testing.expect_value(t, len(nums), 2)
	testing.expect_value(t, s, "z")

	n: int
	testing.expect_value(t, msgpack.read_into(&d, &n, alloc), decode_err(.Unexpected_Eof))
}

@(test)
test_unmarshal_enforces_max_depth :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Tree :: struct {
		child: ^Tree,
	}
	// {"child": {"child": {"child": nil}}}
	input := []byte {
		0x81, 0xa5, 'c', 'h', 'i', 'l', 'd',
		0x81, 0xa5, 'c', 'h', 'i', 'l', 'd',
		0x81, 0xa5, 'c', 'h', 'i', 'l', 'd', 0xc0,
	}
	tree: Tree
	testing.expect_value(t, msgpack.unmarshal(input, &tree, alloc, max_depth = 3), decode_err(.Max_Depth_Exceeded))
	testing.expect_value(t, msgpack.unmarshal(input, &tree, alloc), nil)
	defer msgpack.destroy(&tree, alloc)
	testing.expect(t, tree.child != nil && tree.child.child != nil && tree.child.child.child == nil)
}

@(test)
test_unmarshal_cstring_and_rune :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Mixed :: struct {
		c: cstring,
		r: rune,
	}
	data, _ := msgpack.marshal(Mixed{c = "hey", r = 'é'}, alloc)
	defer delete(data, alloc)
	out: Mixed
	testing.expect_value(t, msgpack.unmarshal(data, &out, alloc), nil)
	defer msgpack.destroy(&out, alloc)
	testing.expect_value(t, string(out.c), "hey")
	testing.expect_value(t, out.r, 'é')
}
