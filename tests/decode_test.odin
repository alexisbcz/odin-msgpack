package msgpack_tests

import msgpack ".."
import "core:testing"

@(test)
test_peek_kind_reports_every_family :: proc(t: ^testing.T) {
	Case :: struct {
		input: []byte,
		kind:  msgpack.Kind,
	}
	cases := []Case {
		{{0xc0}, .Nil},
		{{0xc3}, .Bool},
		{{0x01}, .Int},
		{{0xe5}, .Int},
		{{0xd3, 0, 0, 0, 0, 0, 0, 0, 0}, .Int},
		{{0xcb, 0, 0, 0, 0, 0, 0, 0, 0}, .Float},
		{{0xa1, 'a'}, .String},
		{{0xc4, 0}, .Binary},
		{{0x90}, .Array},
		{{0x80}, .Map},
		{{0xd4, 0x01, 0x00}, .Extension},
		{{0xd6, 0xff, 0, 0, 0, 0}, .Timestamp},
	}
	for c in cases {
		d: msgpack.Decoder
		msgpack.decoder_init(&d, c.input)
		kind, err := msgpack.peek_kind(&d)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, kind, c.kind)
		testing.expect_value(t, d.pos, 0)
	}
}

@(test)
test_peek_kind_rejects_reserved_byte :: proc(t: ^testing.T) {
	d: msgpack.Decoder
	msgpack.decoder_init(&d, {0xc1})
	_, err := msgpack.peek_kind(&d)
	testing.expect_value(t, err, decode_err(.Invalid_Format))
}

@(test)
test_read_int_accepts_every_width :: proc(t: ^testing.T) {
	Case :: struct {
		input: []byte,
		value: i64,
	}
	cases := []Case {
		{{0x7f}, 127},
		{{0xe0}, -32},
		{{0xcc, 0xff}, 255},
		{{0xcd, 0x01, 0x00}, 256},
		{{0xce, 0x00, 0x01, 0x00, 0x00}, 65536},
		{{0xcf, 0, 0, 0, 1, 0, 0, 0, 0}, 0x1_0000_0000},
		{{0xd0, 0x80}, -128},
		{{0xd1, 0x80, 0x00}, -32768},
		{{0xd2, 0x80, 0, 0, 0}, i64(min(i32))},
		{{0xd3, 0x80, 0, 0, 0, 0, 0, 0, 0}, min(i64)},
	}
	for c in cases {
		d: msgpack.Decoder
		msgpack.decoder_init(&d, c.input)
		v, err := msgpack.read_int(&d)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, v, c.value)
		testing.expect_value(t, msgpack.decoder_remaining(&d), 0)
	}
}

@(test)
test_read_int_overflow_keeps_position :: proc(t: ^testing.T) {
	d: msgpack.Decoder
	msgpack.decoder_init(&d, {0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff})
	_, err := msgpack.read_int(&d)
	testing.expect_value(t, err, decode_err(.Integer_Overflow))
	testing.expect_value(t, d.pos, 0)
	u, uerr := msgpack.read_uint(&d)
	testing.expect_value(t, uerr, nil)
	testing.expect_value(t, u, max(u64))
}

@(test)
test_read_uint_rejects_negative :: proc(t: ^testing.T) {
	d: msgpack.Decoder
	msgpack.decoder_init(&d, {0xff})
	_, err := msgpack.read_uint(&d)
	testing.expect_value(t, err, decode_err(.Integer_Overflow))
}

@(test)
test_read_wrong_type_is_mismatch :: proc(t: ^testing.T) {
	d: msgpack.Decoder
	msgpack.decoder_init(&d, {0xa1, 'x'})
	_, ierr := msgpack.read_int(&d)
	testing.expect_value(t, ierr, decode_err(.Type_Mismatch))
	_, berr := msgpack.read_bool(&d)
	testing.expect_value(t, berr, decode_err(.Type_Mismatch))
	testing.expect_value(t, msgpack.read_nil(&d), decode_err(.Type_Mismatch))
	_, aerr := msgpack.read_array_header(&d)
	testing.expect_value(t, aerr, decode_err(.Type_Mismatch))
	s, serr := msgpack.read_str(&d)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, s, "x")
}

@(test)
test_read_float_widths_and_ints :: proc(t: ^testing.T) {
	d: msgpack.Decoder
	msgpack.decoder_init(&d, {0xca, 0x3f, 0xc0, 0x00, 0x00, 0xcb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0, 0x07})
	a, _ := msgpack.read_float(&d)
	b, _ := msgpack.read_float(&d)
	c, err := msgpack.read_float(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, a, 1.5)
	testing.expect_value(t, b, 1.5)
	testing.expect_value(t, c, 7.0)
}

@(test)
test_read_str_borrows_input :: proc(t: ^testing.T) {
	input := []byte{0xd9, 0x03, 'a', 'b', 'c'}
	d: msgpack.Decoder
	msgpack.decoder_init(&d, input)
	s, err := msgpack.read_str(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, s, "abc")
	testing.expect(t, raw_data(s) == &input[2], "read_str must not copy")
}

@(test)
test_read_bin_all_widths :: proc(t: ^testing.T) {
	d: msgpack.Decoder
	msgpack.decoder_init(&d, {0xc4, 0x01, 0xaa, 0xc5, 0x00, 0x01, 0xbb, 0xc6, 0, 0, 0, 1, 0xcc})
	for want in ([]byte{0xaa, 0xbb, 0xcc}) {
		b, err := msgpack.read_bin(&d)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, len(b), 1)
		testing.expect_value(t, b[0], want)
	}
}

@(test)
test_truncated_inputs_report_eof :: proc(t: ^testing.T) {
	inputs := [][]byte {
		{},
		{0xcd, 0x01},
		{0xa3, 'a'},
		{0xd9},
		{0xc4, 0x05, 1, 2},
		{0xcb, 0, 0, 0},
		{0xd6, 0xff, 0, 0},
		{0xc7, 0x02},
	}
	for input in inputs {
		d: msgpack.Decoder
		msgpack.decoder_init(&d, input)
		err := msgpack.skip(&d)
		testing.expectf(t, err == decode_err(.Unexpected_Eof), "input %x: got %v", input, err)
		testing.expect_value(t, d.pos, 0)
	}
}

@(test)
test_container_count_larger_than_input_fails_fast :: proc(t: ^testing.T) {
	d: msgpack.Decoder
	// An array32 that claims four billion items but carries none.
	msgpack.decoder_init(&d, {0xdd, 0xff, 0xff, 0xff, 0xff})
	_, err := msgpack.read_array_header(&d)
	testing.expect_value(t, err, decode_err(.Unexpected_Eof))

	msgpack.decoder_init(&d, {0x82, 0x01, 0x02})
	_, merr := msgpack.read_map_header(&d)
	testing.expect_value(t, merr, decode_err(.Unexpected_Eof))
}

@(test)
test_read_ext_returns_type_and_payload :: proc(t: ^testing.T) {
	d: msgpack.Decoder
	msgpack.decoder_init(&d, {0xd5, 0x2a, 0x01, 0x02, 0xc7, 0x03, 0x80, 7, 8, 9})
	type, data, err := msgpack.read_ext(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, type, 42)
	testing.expect_value(t, len(data), 2)
	type, data, err = msgpack.read_ext(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, type, -128)
	testing.expect_value(t, len(data), 3)
	testing.expect_value(t, data[2], 9)
}

@(test)
test_read_timestamp_all_layouts :: proc(t: ^testing.T) {
	d: msgpack.Decoder
	msgpack.decoder_init(&d, {
		0xd6, 0xff, 0, 0, 0, 1,
		0xd7, 0xff, 0, 0, 0, 0x04, 0, 0, 0, 1,
		0xc7, 12, 0xff, 0, 0, 0, 5, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	})
	a, _ := msgpack.read_timestamp(&d)
	b, _ := msgpack.read_timestamp(&d)
	c, err := msgpack.read_timestamp(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, a, msgpack.Timestamp{1, 0})
	testing.expect_value(t, b, msgpack.Timestamp{1, 1})
	testing.expect_value(t, c, msgpack.Timestamp{-1, 5})
}

@(test)
test_read_timestamp_rejects_bad_payloads :: proc(t: ^testing.T) {
	d: msgpack.Decoder
	// Nanoseconds of 1e9 in the 96-bit layout.
	msgpack.decoder_init(&d, {0xc7, 12, 0xff, 0x3b, 0x9a, 0xca, 0x00, 0, 0, 0, 0, 0, 0, 0, 0})
	_, err := msgpack.read_timestamp(&d)
	testing.expect_value(t, err, decode_err(.Invalid_Timestamp))

	// A timestamp payload of 2 bytes is not a defined layout.
	msgpack.decoder_init(&d, {0xd5, 0xff, 0, 0})
	_, err = msgpack.read_timestamp(&d)
	testing.expect_value(t, err, decode_err(.Invalid_Timestamp))

	// An extension of another type is not a timestamp.
	msgpack.decoder_init(&d, {0xd6, 0x01, 0, 0, 0, 0})
	_, err = msgpack.read_timestamp(&d)
	testing.expect_value(t, err, decode_err(.Type_Mismatch))
}

@(test)
test_skip_walks_nested_containers :: proc(t: ^testing.T) {
	d: msgpack.Decoder
	// {"a": [1, {"b": nil}], "c": bin(1)} followed by true.
	msgpack.decoder_init(&d, {0x82, 0xa1, 'a', 0x92, 0x01, 0x81, 0xa1, 'b', 0xc0, 0xa1, 'c', 0xc4, 0x01, 0x00, 0xc3})
	testing.expect_value(t, msgpack.skip(&d), nil)
	b, err := msgpack.read_bool(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, b, true)
	testing.expect_value(t, d.depth, 0)
}

@(test)
test_skip_enforces_max_depth :: proc(t: ^testing.T) {
	nested: [10]byte
	for &b in nested {
		b = 0x91
	}
	d: msgpack.Decoder
	msgpack.decoder_init(&d, nested[:], max_depth = 4)
	testing.expect_value(t, msgpack.skip(&d), decode_err(.Max_Depth_Exceeded))
	testing.expect_value(t, d.pos, 0)
	testing.expect_value(t, d.depth, 0)
}
