# ADR-0002: Packed/Unpacked Field Support in Code Generation

## Status

Proposed

## Context

proto-zig already supports encoding and decoding packed repeated fields at runtime:

- `decode.zig:131-136` detects packed wire format and calls `decode_packed_repeated()`
- `encode.zig:299-331` encodes packed fields with length-delimited format
- `mini_table.zig:111` has `is_packed` field in `MiniTableField`

However, the code generator (`descriptor_parser.zig:375`) hardcodes `is_packed = false`:

```zig
.is_packed = false, // TODO: Read from options
```

This means generated MiniTables always encode repeated scalars as unpacked, which:
- Produces larger wire output (tag per element instead of single length-delimited blob)
- Differs from proto3 default behavior (packed is default for repeated scalars)
- Fails differential testing against upb which uses proto3 semantics

### Proto3 Semantics

In proto3, repeated scalar fields are packed by default. The `[packed=false]` option can explicitly disable packing. The descriptor stores this in `FieldDescriptorProto.options.packed` (field 8 → field 2).

### What Needs to Change

1. **Bootstrap schemas**: Add `FieldOptions` message type to parse field options
2. **Descriptor parser**: Read `options.packed` from `FieldDescriptorProto`
3. **Proto3 defaults**: If `packed` is not explicitly set, default to true for packable repeated fields

## Decision

Implement full packed field support in code generation by:

1. Adding `FieldOptions` to bootstrap schemas
2. Parsing `FieldDescriptorProto.options` (field 8)
3. Reading `FieldOptions.packed` (field 2)
4. Applying proto3 default semantics

### Components Modified

- **bootstrap.zig**: Add FieldOptions MiniTable
- **descriptor_parser.zig**: Parse options and extract packed flag

### Proto3 Default Logic

```zig
fn determine_is_packed(label: FieldLabel, field_type: FieldType, explicit_packed: ?bool) bool {
    // Only applies to repeated fields
    if (label != .repeated) return false;

    // Only scalar types can be packed
    if (!is_packable(field_type)) return false;

    // Explicit setting overrides default
    if (explicit_packed) |packed| return packed;

    // Proto3 default: repeated scalars are packed
    return true;
}
```

### Bootstrap Schema Addition

Add to `bootstrap.zig`:

```zig
pub const FieldOptions_fields = [_]MiniTableField{
    .{
        .number = 2, // packed
        .offset = 0,
        .presence = 1, // has_packed hasbit
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BOOL,
        .mode = .scalar,
        .is_packed = false,
    },
};
```

## Consequences

### Positive

- Generated code matches proto3 semantics
- Wire format compatibility with other implementations
- Smaller encoded size for repeated scalar fields (proto3 default)
- Differential tests against upb will pass

### Negative

- Bootstrap schemas grow slightly
- Must handle presence tracking for optional `packed` field

### Risks

- None significant - this is standard proto3 behavior

## Implementation Plan

1. Add `FieldOptions` message to `bootstrap.zig` with `packed` field (number=2)
2. Update `parseFieldDescriptor` in `descriptor_parser.zig` to:
   - Get `options` submessage from field 8
   - Read `packed` boolean from field 2
   - Apply proto3 default if not explicitly set
3. Add test `.proto` with explicit `[packed=false]` field
4. Run differential tests to verify compatibility with upb
5. Update README.md changelog

## References

- FieldOptions definition: `protobuf/src/google/protobuf/descriptor.proto:682-712`
- Current decode logic: `src/wire/decode.zig:131-136`
- Current encode logic: `src/wire/encode.zig:299-331`
- upb packed handling: `upb/wire/encode.c:478-589`
