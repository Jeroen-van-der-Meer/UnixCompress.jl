"""
    decompress(input_path, output_path)

Decompress a `.Z` file produced by Unix compress (LZW).

# Arguments

- `input_path`: Path to input file.
- `output_path`: Defaults to `input_path` with the `.Z` suffix stripped.
"""
function decompress(
    input_path::AbstractString,
    output_path::AbstractString = _default_decompress_path(input_path)
)
    # Read file into memory and wrap in IOBuffer for efficient byte-by-byte iteration
    input_data = read(input_path)
    input = IOBuffer(input_data)
    output = IOBuffer()
    decompress(input, output)
    write(output_path, take!(output))
end

"""
    decompress(input::Vector{UInt8}) -> Vector{UInt8}

Decompress a byte vector produced by Unix compress (LZW).
"""
function decompress(input::Vector{UInt8})
    input_io = IOBuffer(input)
    output_io = IOBuffer()
    decompress(input_io, output_io)
    return take!(output_io)
end

"""
    decompress(input::IO, output::IO)

Decompress from an input stream to an output stream using the Unix decompress
(LZW) algorithm.
"""
function decompress(input::IO, output::IO)
    # Read 3-byte header
    header = Vector{UInt8}(undef, 3)
    bytes_read = readbytes!(input, header, 3)

    if bytes_read < 3
        error("Input too short to be a valid Unix compress file.")
    end

    # Parse header bytes. The first two are the magic header for Unix
    # compress. The third byte consists of three fixed bits (100) followed five
    # bits indicating the maximum code length. These three fixed bits are a
    # legacy artifact. Bit 7 (0x80) is the block-compress flag, which enables
    # support for the CLEAR code.
    if header[1] != 0x1f || header[2] != 0x9d
        error("""
              Based on the input header, input file does not appear to be
              compressed with Unix compress.
              """)
    end
    block_mode = (header[3] & 0x80) != 0
    max_code_length = Int(header[3] & 0b00011111)
    if max_code_length < 9 || max_code_length > 16
        error("Invalid max code length $max_code_length in header.")
    end
    max_code = UInt16((1 << max_code_length) - 1)

    # Decode table stored as suffix/prefix chains. For codes 0-255, the suffix
    # is the byte itself and the prefix is unused. For codes 257+, walking the
    # chain prefix[code] -> prefix[prefix[code]] -> ... -> single byte recovers
    # the full byte string.
    suffix = Vector{UInt8}(undef, max_code + 1)
    prefix = Vector{UInt16}(undef, max_code + 1)
    for b in 0x00:0xff
        suffix[b + 1] = b
    end
    # Reusable stack buffer for decoding a code into bytes (reverse order).
    stack = Vector{UInt8}(undef, max_code + 1)

    # latest_code indicates the largest code currently in our decode table, or
    # equivalently, the one added most recently. In block mode, code 256 is
    # reserved for CLEAR, so the first new code is 257. In non-block mode,
    # there is no CLEAR code and the first new code is 256.
    latest_code = block_mode ? CLEAR_CODE : CLEAR_CODE - UInt16(1)
    # Unix compress uses variable-length codes, starting with length 9 and
    # gradually increasing as we progress through the input file (unless a
    # CLEAR signal is received).
    code_length = INIT_CODE_LENGTH
    max_code_of_current_length = 1 << code_length
    # prev_code tracks the previous code for building new decode table entries.
    # has_prev_code is false at the start and after a CLEAR. We can't use a
    # sentinel code value for this, since in non-block mode 256 is an ordinary
    # code, and at 16 bits every UInt16 value is a valid code.
    prev_code = UInt16(0)
    has_prev_code = false

    # Process input in groups of code_length bytes (= 8 codes per group).
    # Unix compress organizes codes into groups that align to code_length-byte
    # boundaries. After a CLEAR code or a code length increase, the remaining
    # codes in the group are padding.
    group = Vector{UInt8}(undef, max_code_length)
    code_mask = UInt16((1 << code_length) - 1)
    while !eof(input)
        group_size = code_length
        group_bytes = readbytes!(input, group, group_size)

        if group_bytes == 0
            break
        end

        n_codes = (group_bytes * 8) ÷ code_length

        # Extract codes from this group using a local bit buffer.
        bit_buffer = UInt32(0)
        bits_in_buffer = 0
        gpos = 1  # 1-based indexing for Julia

        for _ in 1:n_codes
            # Fill the bit buffer until we have enough bits for one code.
            while bits_in_buffer < code_length && gpos <= group_bytes
                bit_buffer |= UInt32(group[gpos]) << bits_in_buffer
                bits_in_buffer += 8
                gpos += 1
            end

            if bits_in_buffer < code_length
                break  # Not enough bits for a full code
            end

            code = UInt16(bit_buffer & code_mask)
            bit_buffer >>>= code_length
            bits_in_buffer -= code_length

            # CLEAR: reset the decode table and all associated state. The
            # remaining codes in this group are padding and will be skipped.
            if block_mode && code == CLEAR_CODE
                latest_code = CLEAR_CODE
                code_length = INIT_CODE_LENGTH
                max_code_of_current_length = 1 << code_length
                code_mask = UInt16((1 << code_length) - 1)
                has_prev_code = false
                break
            end

            # First code after start or CLEAR: just output the single byte.
            if !has_prev_code
                if code > 0x00ff
                    error("Corrupt input: expected a literal byte code, got $code.")
                end
                write(output, UInt8(code))
                prev_code = code
                has_prev_code = true
                continue
            end

            # Decode the current code into bytes using the suffix/prefix chain.
            # For the KwKwK exceptional case (code == latest_code + 1), the
            # string is prev_string + first_byte_of_prev_string. We handle
            # this by walking prev_code's chain and appending its first byte.
            # Any code beyond latest_code + 1 isn't in the table yet, so the
            # input must be corrupt. (Comparing with latest_code + 1 directly
            # would overflow when latest_code == 0xffff.)
            is_kwkwk = code > latest_code
            if is_kwkwk && code != latest_code + UInt16(1)
                error("Corrupt input: code $code is beyond the next free code $(latest_code + 1).")
            end
            c = is_kwkwk ? prev_code : code
            stack_len = 0
            while c > 0x00ff
                stack_len += 1
                stack[stack_len] = suffix[c + 1]
                c = prefix[c + 1]
            end
            stack_len += 1
            stack[stack_len] = UInt8(c)
            first_byte = UInt8(c)

            # Output the decoded bytes (stack is in reverse order).
            for i in stack_len:-1:1
                write(output, stack[i])
            end
            if is_kwkwk
                write(output, first_byte)
            end

            # Add a new entry to the decode table: prev_string + first_byte.
            code_length_increased = false
            if latest_code < max_code
                latest_code += UInt16(1)
                suffix[latest_code + 1] = first_byte
                prefix[latest_code + 1] = prev_code
                # The decompressor bumps code_length one entry earlier than the
                # compressor ("early change") because the decompressor's table
                # lags by one entry relative to the compressor's.
                if (latest_code >= max_code_of_current_length - 1) &&
                        (code_length < max_code_length)
                    code_length += 1
                    max_code_of_current_length <<= 1
                    code_mask = UInt16((1 << code_length) - 1)
                    code_length_increased = true
                end
            end

            prev_code = code

            # When the code length increases, the compressor pads the current
            # group, so we skip the rest of it. In block mode the increase
            # always coincides with the end of a group, but in non-block mode
            # (where the first new code is 256 rather than 257) it falls one
            # code into a group.
            if code_length_increased
                break
            end
        end
    end
end

function _default_decompress_path(input_path::AbstractString)
    if endswith(input_path, ".Z")
        return chop(input_path; tail = 2)
    else
        error("Please specify output file name!")
    end
end

# `uncompress` more historically accurate than `decompress`. I'll make one into
# a synonym of the other.
uncompress = decompress
