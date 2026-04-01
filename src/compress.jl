const CHECK_GAP = 10000
const ROOT_NODE = Int32(1)
const EMPTY_NODE = Int32(0)

# For performance reasons, we use a matrix-based trie to implement the code
# table of our compress function. The children matrix has dimensions (256, N)
# where N is the maximum number of nodes. children[byte+1, node] gives the
# child node for that (node, byte) pair, or 0 meaning "no child".
#
# Node numbering:
#   0         = no child
#   1         = root
#   code + 2  = trie node for LZW code `code`
# The code for a node n >= 2 is simply n - 2.
@inline node_for_code(code::UInt16) = Int32(code) + Int32(2)
@inline code_for_node(node::Int32) = UInt16(node - 2)

# Unix compress always starts off with codes for the 256 individual initial
# bytes, which it maps to itself. We initialize root's children accordingly.
function initialize_trie!(children::Matrix{Int32})
    fill!(children, EMPTY_NODE)
    for b in UInt16(0):UInt16(255)
        children[b + 1, ROOT_NODE] = node_for_code(b)
    end
end

"""
    compress(input_path, output_path; max_code_length = 16)

Compress a file using the Unix compress (LZW) algorithm.

# Arguments

- `input_path`: Path to input file.
- `output_path`: Defaults to `input_path` with a `.Z` suffix appended.

# Keyword Arguments

- `max_code_length = 16`: Maximum LZW code width in bits.
"""
function compress(
    input_path::AbstractString,
    output_path::AbstractString = "$input_path.Z";
    max_code_length::Integer = 16
)
    # Read file into memory and wrap in IOBuffer for efficient byte-by-byte iteration
    input_data = read(input_path)
    input = IOBuffer(input_data)
    output = IOBuffer()
    compress(input, output; max_code_length = max_code_length)
    write(output_path, take!(output))
end

"""
    compress(input::Vector{UInt8}; max_code_length = 16) -> Vector{UInt8}

Compress a byte vector using the Unix compress (LZW) algorithm.
"""
function compress(input::Vector{UInt8}; max_code_length::Integer = 16)
    input_io = IOBuffer(input)
    output_io = IOBuffer()
    compress(input_io, output_io; max_code_length = max_code_length)
    return take!(output_io)
end

"""
    compress(input::IO, output::IO; max_code_length = 16)

Compress from an input stream to an output stream using the Unix compress (LZW)
algorithm.
"""
function compress(input::IO, output::IO; max_code_length::Integer = 16)
    # Unix compress is hard-coded not to allow code length beyond 16 bits. This
    # was because of memory constraints, along with the observation that larger
    # codes gave little improvements in compression performance.
    if max_code_length < 9 || max_code_length > 16
        error("""
              Invalid max code length. Unix compress allows the max code length
              to be anywhere from 9 to 16.
              """)
    end
    max_code = 0x0001 << max_code_length - 0x0001

    # Write three header bytes. The first two are the magic header for Unix
    # compress. The third byte consists of three fixed bits (100) followed five
    # bits indicating the maximum code length. These three fixed bits are a
    # legacy artifact.
    write(output, 0x1f, 0x9d, 0x80 | UInt8(max_code_length))

    # Matrix trie: children[byte+1, node] = child node (or 0 for no child).
    max_node = node_for_code(max_code)
    children = Matrix{Int32}(undef, 256, max_node)
    initialize_trie!(children)

    # latest_code indicates the largest code currently in our code table, or
    # equivalently, the one added most recently. Note that we start out at
    # 0x0100 (256) and not 0x00ff (255). This is because Unix compress reserves
    # the code 256 for CLEAR, which signals that the entire code table should
    # be reset.
    latest_code = CLEAR_CODE
    # Unix compress uses variable-length codes, starting with length 9 and
    # gradually increasing as we progress through the input file (unless a
    # CLEAR signal is received).
    code_length = INIT_CODE_LENGTH
    max_code_of_current_length = 1 << code_length
    # To properly deal with codes of an irregular amount of bits, we first
    # write our codes to a bit buffer before flushing complete bytes to out.
    # We use UInt32 so that shifting a 16-bit code left by up to 7 bits never
    # overflows.
    bit_buffer = UInt32(0)
    # bits_in_buffer indicates how many bits of the bit buffer are presently
    # filled (always 0-7 after flushing).
    bits_in_buffer = 0
    # CLEAR signal state. When the code table fills up and the compression
    # ratio starts to degrade, we emit a CLEAR code (256) and reset the table.
    table_full = false
    bytes_in = 0
    checkpoint = CHECK_GAP
    ratio = 0
    # epoch_offset tracks the data byte count at the start of the current
    # code_length epoch. Groups of 8 codes (= code_length bytes) are aligned
    # relative to this offset, not the absolute data start.
    epoch_offset = 3
    # current_node indicates where we are in the trie. We start off at the root.
    current_node = ROOT_NODE

    # Process input byte-by-byte
    bytes_in = 0
    while !eof(input)
        byte = read(input, UInt8)
        bytes_in += 1
        # If the current node has the current byte as one of its children, that
        # means that the current pattern has been encountered before. We simply
        # traverse the trie and proceed to the next byte.
        child = children[byte + 1, current_node]
        if child != EMPTY_NODE
            current_node = child
            continue
        end
        # If there's no such child, a new pattern is encountered. We write the
        # code of the current node to the output. Because the code is a
        # possibly irregular number of bits, this involves quite a bit
        # of tedious bitshifting (pun intended).
        code = code_for_node(current_node)
        bit_buffer |= UInt32(code) << bits_in_buffer
        bits_in_buffer += code_length
        while bits_in_buffer >= 8
            write(output, UInt8(bit_buffer & 0xff))
            bit_buffer >>>= 8
            bits_in_buffer -= 8
        end
        # Append a new node to our code table provided that we haven't reached
        # the hard limit of max_code codes.
        if !table_full
            if latest_code < max_code
                latest_code += UInt16(1)
                children[byte + 1, current_node] = node_for_code(latest_code)
                if latest_code == max_code_of_current_length
                    code_length += 1
                    max_code_of_current_length <<= 1
                    epoch_offset = position(output)
                end
            end
            if latest_code >= max_code
                table_full = true
            end
        end
        # When the code table is full, periodically check if the compression
        # ratio is degrading. If so, emit a CLEAR code and reset the table.
        if table_full && (bytes_in >= checkpoint)
            checkpoint = bytes_in + CHECK_GAP
            bytes_out = position(output)
            current_ratio = (bytes_in << 8) ÷ bytes_out
            if current_ratio >= ratio
                ratio = current_ratio
            else
                # Emit CLEAR code at the current code width.
                bit_buffer |= UInt32(CLEAR_CODE) << bits_in_buffer
                bits_in_buffer += code_length
                while bits_in_buffer >= 8
                    write(output, UInt8(bit_buffer & 0xff))
                    bit_buffer >>>= 8
                    bits_in_buffer -= 8
                end
                # Flush any remaining partial byte.
                if bits_in_buffer > 0
                    write(output, UInt8(bit_buffer & 0xff))
                    bits_in_buffer = 0
                    bit_buffer = UInt32(0)
                end
                # Pad output to the next code_length-byte boundary relative to
                # the current epoch. Unix compress organizes codes into groups
                # of 8 codes (= code_length bytes), and CLEAR must land on a
                # group boundary.
                local_bytes = position(output) - epoch_offset
                padding = (code_length - local_bytes % code_length) % code_length
                for _ in 1:padding
                    write(output, 0x00)
                end
                epoch_offset = position(output)
                # Reset the code table and all associated state.
                initialize_trie!(children)
                latest_code = CLEAR_CODE
                code_length = INIT_CODE_LENGTH
                max_code_of_current_length = 1 << code_length
                table_full = false
                ratio = 0
            end
        end
        current_node = children[byte + 1, ROOT_NODE]
    end
    # When we've reached the end of the file, we output the remaining bits in
    # the buffer, as well as the code of the node that we're ending at.
    if current_node != ROOT_NODE
        code = code_for_node(current_node)
        bit_buffer |= UInt32(code) << bits_in_buffer
        bits_in_buffer += code_length
        while bits_in_buffer >= 8
            write(output, UInt8(bit_buffer & 0xff))
            bit_buffer >>>= 8
            bits_in_buffer -= 8
        end
        if bits_in_buffer > 0
            write(output, UInt8(bit_buffer & 0xff))
        end
    end
end
