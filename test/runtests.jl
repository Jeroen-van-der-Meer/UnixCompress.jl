using UnixCompress
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

@testset "Edge cases" begin
    @test uncompress(compress(UInt8[])) == UInt8[]
    @test uncompress(compress([0x00])) == [0x00]
end
