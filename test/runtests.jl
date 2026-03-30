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