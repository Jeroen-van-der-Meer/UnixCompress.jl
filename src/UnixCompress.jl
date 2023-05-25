module UnixCompress

export compress

# TO DO:
# - Check if we increase the variable code length at the correct moment.
# - Implement CLEAR signal.
# - Implement decompress().
# - Add tests.
# - Add docs.
# - Fix off-by-one bug.

# For performance reasons, we use tries to implement the code table of our
# compress function.
struct TableNode
    children::Dict{UInt8, TableNode}
    # All our codes shall be stored in 16 bits. We will use an auxiliary
    # variable to indicate how many of these bits should actually be written
    # to output. As Unix compress is variable-size, this number changes over time.
    # We allow a table node to have a value of nothing --- a value we reserve
    # for the root node. Besides semantics, this lets us deal with the empty
    # file.
    value::Union{Nothing, UInt16}
end

function TableNode(value::UInt16)
    children = Dict{UInt8, TableNode}()
    return TableNode(children, value)
end

# Unix compress always starts off with codes for individual the 256 initial bytes,
# which it maps to itself.
function initialize_table()
    children = Dict(i => TableNode(UInt16(i)) for i in 0x00:0xff)
    return TableNode(children, nothing)
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
    if max_code_length < 9 || max_code_length > 17
        throw(DomainError(max_code_length, "Invalid max code length!"))
    end
    max_code = 0x0001 << max_code_length - 0x0001
    # We write three header bytes. The first two are the magic header for Unix
    # compress. The third byte consists of three fixed bits (100) followed five
    # bits indicating the maximum code length. These three fixed bits are a
    # legacy artifact.
    write(output, 0x1f, 0x9d, 0x80 | UInt8(max_code_length))
    root = initialize_table()
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
    # write our codes to an output buffer before sending it to the output IO.
    output_buffer = 0x0000
    # current_bit_position indicates how many bits of the output buffer are
    # presently filled.
    current_bit_position = 0x00
    # current_node indicates where we are in the trie. We start off at the root.
    current_node = root
    for byte in readeach(input, UInt8)
        # If the current node has the current byte as one of its children, that
        # means that the current pattern has been encountered before. We simply
        # traverse the trie and proceed to the next byte.
        if haskey(current_node.children, byte)
            current_node = current_node.children[byte]
        # If there's no such child, a new pattern is encountered. We write the
        # value of the current node to the output IO. Because the value is a
        # code of a possibly irregular amount of bits, this envolves quite a bit
        # (pun intended) of tedious bitshifting.
        else
            code = current_node.value
            output_buffer |= (code << current_bit_position)
            current_bit_position += code_length
            # If the entire buffer is filled up, we write it to output and put
            # the remaining code bits in a cleared buffer.
            if current_bit_position >= 0x10
                write(output, output_buffer)
                current_bit_position -= 0x10
                output_buffer = code >>> (0x10 - current_bit_position)
            # If the buffer isn't full, we write only the second byte to output
            # and bitshift the remaining bits in the buffer accordingly.
            else
                write(output, output_buffer % UInt8)
                output_buffer >>>= 8
                current_bit_position -= 0x08
            end
            # Append a new node to our code table provided that we haven't
            # reached the hard limit of max_code codes.
            if latest_code <= max_code
                latest_code += 0x0001
                new_node = TableNode(latest_code)
                current_node.children[byte] = new_node
                if latest_code == max_code_of_current_length
                    code_length += 0x01
                    max_code_of_current_length <<= 1
                end
            end
            current_node = root.children[byte]
        end
    end
    # When we've reached the end of the file, we output the remaining bits in
    # the buffer, as well as in the code of the node that we're ending at.
    code = current_node.value
    # If code === nothing, we don't actually write any output data. In particular,
    # if we compress an empty file called foo and we already have a nonempty file
    # called foo.Z, then foo.Z will not be overwritten by an empty file. Unix
    # compress exhibits the same pathology.
    if !isnothing(code)
        output_buffer |= (code << current_bit_position)
        current_bit_position += code_length
        write(output, output_buffer)
        if current_bit_position > 0x10
            output_buffer = code >>> (0x20 - current_bit_position)
            write(output, output_buffer % UInt8)
        end
    end
end

end # module UnixCompress
