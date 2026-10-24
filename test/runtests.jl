using UnixCompress
using Random
using Test

const TEST_DATA_PATH = joinpath(@__DIR__, "testdata")

const TEST_FILES = [
    "asyoulik.txt",
    "alice29.txt",
    "cp.html",
    "fields.c",
    "grammar.lsp",
    "kennedy.xls",
    "lcet10.txt",
    "plrabn12.txt",
    "ptt5",
    "sum",
    "xargs.1",
]

@testset "Compress" begin
    for f in TEST_FILES
        path = joinpath(TEST_DATA_PATH, f)
        compress(path)
        @test read("$path.Z") == read("$path.Z_original")
        rm("$path.Z")
    end
end

@testset "Decompress" begin
    for f in TEST_FILES
        path = joinpath(TEST_DATA_PATH, f)
        outpath = "$path.decompressed"
        decompress("$path.Z_original", outpath)
        @test read(outpath) == read(path)
        rm(outpath)
    end
end

# Non-block mode is the pre-compress-3.0 format: no CLEAR code, and code 256 is
# an ordinary table entry. Modern ncompress can no longer produce it, so these
# files were made with an encoder modelled on compress 4.0 and verified to
# decompress correctly with both ncompress 5.0 and gzip.
@testset "Decompress non-block mode" begin
    for (f, z) in [("lcet10.txt", "lcet10.txt.Z_nonblock"),
                   ("alice29.txt", "alice29.txt.Z_nonblock12")]
        compressed = read(joinpath(TEST_DATA_PATH, z))
        @test compressed[3] & 0x80 == 0
        @test decompress(compressed) == read(joinpath(TEST_DATA_PATH, f))
    end
end

@testset "Non-default max_code_length" begin
    path = joinpath(TEST_DATA_PATH, "kennedy.xls")
    for bits in 9:16
        zpath = "$path.$bits.Z"
        outpath = "$path.$bits.roundtrip"
        compress(path, zpath; max_code_length=bits)
        decompress(zpath, outpath)
        @test read(outpath) == read(path)
        rm(zpath)
        rm(outpath)
    end
end

# A minimal non-seekable output stream: it supports writing bytes but not
# `position`, like a pipe or a terminal.
struct WriteOnlyIO <: IO
    buffer::IOBuffer
end
Base.write(io::WriteOnlyIO, byte::UInt8) = write(io.buffer, byte)

@testset "Compress to IO" begin
    data = read(joinpath(TEST_DATA_PATH, "kennedy.xls"))
    for bits in (9, 12, 16)
        expected = compress(data; max_code_length = bits)

        io = WriteOnlyIO(IOBuffer())
        compress(IOBuffer(data), io; max_code_length = bits)
        @test take!(io.buffer) == expected

        # Output that already has content must not affect the result.
        prefix = zeros(UInt8, 1_000_003)
        io = IOBuffer()
        write(io, prefix)
        compress(IOBuffer(data), io; max_code_length = bits)
        @test take!(io)[length(prefix) + 1 : end] == expected
    end
end

# Pack a sequence of 9-bit codes into a block-mode .Z stream. Only valid for
# short sequences that don't reach a code length increase.
function pack_9bit_codes(codes)
    out = UInt8[0x1f, 0x9d, 0x90]
    bit_buffer = UInt32(0)
    bits_in_buffer = 0
    for code in codes
        bit_buffer |= UInt32(code) << bits_in_buffer
        bits_in_buffer += 9
        while bits_in_buffer >= 8
            push!(out, UInt8(bit_buffer & 0xff))
            bit_buffer >>>= 8
            bits_in_buffer -= 8
        end
    end
    bits_in_buffer > 0 && push!(out, UInt8(bit_buffer & 0xff))
    return out
end

@testset "Corrupt input" begin
    # Sanity check: the KwKwK case (code == next free code) is valid.
    @test decompress(pack_9bit_codes([0x41, 257])) == Vector{UInt8}("AAA")
    # First code must be a literal byte.
    @test_throws ErrorException decompress(pack_9bit_codes([300]))
    # Code beyond the next free code.
    @test_throws ErrorException decompress(pack_9bit_codes([0x41, 258]))
    @test_throws ErrorException decompress(pack_9bit_codes([0x41, 0x42, 300]))
    # First code after a CLEAR must be a literal byte. The CLEAR's group is
    # padded out to 8 codes, so the bad code starts the next group.
    @test_throws ErrorException decompress(
        pack_9bit_codes([0x41, 256, 0, 0, 0, 0, 0, 0, 300]))

    # Randomly corrupted input must either decompress or throw an
    # ErrorException, never fail with some other exception.
    rng = MersenneTwister(0)
    valid = compress(read(joinpath(TEST_DATA_PATH, "cp.html")))
    unexpected = []
    for _ in 1:1000
        corrupt = copy(valid)
        for _ in 1:rand(rng, 1:3)
            corrupt[rand(rng, 4:length(corrupt))] = rand(rng, UInt8)
        end
        try
            decompress(corrupt)
        catch e
            e isa ErrorException || push!(unexpected, e)
        end
    end
    @test isempty(unexpected)
end

@testset "Edge cases" begin
    @test uncompress(compress(UInt8[])) == UInt8[]
    @test uncompress(compress([0x00])) == [0x00]
end
