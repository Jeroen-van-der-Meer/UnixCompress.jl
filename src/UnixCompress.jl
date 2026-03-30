module UnixCompress

export compress

# TO DO:
# - Implement decompress().
# - Add docs.

const CLEAR_CODE = UInt32(256)
const INIT_CODE_LENGTH = 9
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

function compress(input_path::AbstractString,
                  output_path::AbstractString="$input_path.Z";
                  max_code_length::Integer=16)
    input = open(input_path, "r")
    output = open(output_path, "w")
    compress(input, output; max_code_length)
    close(input)
    close(output)
end

function compress(input::IO,
                  output::IO;
                  max_code_length::Integer=16)
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

    # Read all input at once for performance (avoids per-byte IO overhead).
    input_data = read(input)

    # Accumulate output in a byte vector for performance (avoids per-byte
    # write() calls).
    out = Vector{UInt8}()
    sizehint!(out, length(input_data))

    # We write three header bytes. The first two are the magic header for Unix
    # compress. The third byte consists of three fixed bits (100) followed five
    # bits indicating the maximum code length. These three fixed bits are a
    # legacy artifact.
    push!(out, 0x1f, 0x9d, 0x80 | UInt8(max_code_length))

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
    # current_node indicates where we are in the trie. We start off at the root.
    current_node = ROOT_NODE

    for (bytes_in, byte) in enumerate(input_data)
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
            push!(out, UInt8(bit_buffer & 0xff))
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
            bytes_out = length(out)
            current_ratio = (bytes_in << 8) ÷ bytes_out
            if current_ratio >= ratio
                ratio = current_ratio
            else
                # Emit CLEAR code at the current code width.
                bit_buffer |= UInt32(CLEAR_CODE) << bits_in_buffer
                bits_in_buffer += code_length
                while bits_in_buffer >= 8
                    push!(out, UInt8(bit_buffer & 0xff))
                    bit_buffer >>>= 8
                    bits_in_buffer -= 8
                end
                # Flush any remaining partial byte.
                if bits_in_buffer > 0
                    push!(out, UInt8(bit_buffer & 0xff))
                    bits_in_buffer = 0
                    bit_buffer = UInt32(0)
                end
                # Pad output to the next code_length-byte boundary (relative
                # to the data start after the 3-byte header). Unix compress
                # organizes codes into groups of 8 codes (= code_length bytes),
                # and CLEAR must land on a group boundary.
                data_bytes = length(out) - 3
                padding = (code_length - data_bytes % code_length) % code_length
                for _ in 1:padding
                    push!(out, 0x00)
                end
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
    # If current_node is still at root, the input was empty and we don't write
    # any output data. In particular, if we compress an empty file called foo
    # and we already have a nonempty file called foo.Z, then foo.Z will not be
    # overwritten by an empty file. Unix compress exhibits the same pathology.
    if current_node != ROOT_NODE
        code = code_for_node(current_node)
        bit_buffer |= UInt32(code) << bits_in_buffer
        bits_in_buffer += code_length
        while bits_in_buffer >= 8
            push!(out, UInt8(bit_buffer & 0xff))
            bit_buffer >>>= 8
            bits_in_buffer -= 8
        end
        if bits_in_buffer > 0
            push!(out, UInt8(bit_buffer & 0xff))
        end
    end
    write(output, out)
end

function default_decompress_path(input_path::AbstractString)
    if endswith(input_path, ".Z")
        return input_path[begin : end - 2]
    else
        error("Please specify output file name!")
    end
end

function decompress(input_path::AbstractString, 
                    output_path::AbstractString=default_decompress_path(input_path))
    input = open(input_path, "r")
    output = open(output_path, "w")
    decompress(input, output)
    close(input)
    close(output)
end

function decompress(input::IO, 
                    output::IO)
    # We read three header bytes. The first two are the magic header for Unix
    # compress. The third byte consists of three fixed bits (100) followed five
    # bits indicating the maximum code length. These three fixed bits are a
    # legacy artifact.
    first_byte, second_byte = read(input, UInt8), read(input, UInt8)
    if first_byte != 0x1f || second_byte != 0x9d
        error("""
              Based on the input header, input file does not appear to be
              compressed with Unix compress.
              """)
    end
    third_byte = read(input, UInt8)
    if third_byte & 0b11100000 != 0b10000000
        warn("""
             The header implies that the file may have been compressed by a very
             old version of Unix compress. Proceeding anyway.
             """)
    end
    max_code_length = third_byte & 0b00011111
    max_code = 0x0001 << max_code_length - 0x0001
    # latest_code indicates the largest code current in our code table, or
    # equivalently, the one added most recently. Note that we start out at
    # 0x0100 (256) and not 0x00ff (255). This is because Unix compress reserves
    # the code 256 for CLEAR, which signals that the entire code table should
    # be reset.
    latest_code = 0x0100
    # Unix compress uses variable-length codes, starting with length 9 and
    # gradually increasing as we progress through the input file (unless a
    # CLEAR signal is received).
    code_length = 0x09
    max_code_of_current_length = 0x0001 << code_length
    # To properly deal with codes of an irregular amount of bits, we first
    # write our codes to an input buffer before processing them.
    input_buffer = 0x0000
    # current_bit_position indicates how many bits of the input buffer are
    # presently filled.
    current_bit_position = 0x00
    
    decode_table = Dict{UInt16, Vector{UInt8}}()
    latest_invoked_code = Vector{UInt8}([])

    for byte in readeach(input, UInt8)
        # To do: Some magic bitshifting to extract codes out
    
        # Then, for every code, go through the following logic.
        if code != 0x0100
            # If code has been encountred before, then...
            if code < latest_code
                decode = decode_table[code]
                write(output, decode)
                # This will fail on the very first code! Dirty solution: Use 0x0100
                # to catch that case, since we're never gonna use that code anyway.
                latest_code += 0x0001
                decode_table[latest_code] = latest_invoked_code[:] * decode[begin]
                latest_invoked_code = decode
            # Exceptional case which needs to be handled separately.
            else
                println("Haven't seen this code before!")
            end
        # If code == 0x0100, that indicates a clear signal.
        else
            println("Clearing my decode table!")
        end

    end
end

end # module UnixCompress
