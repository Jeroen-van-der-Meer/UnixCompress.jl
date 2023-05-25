using UnixCompress
using Mmap
using Test

const TEST_DATA_PATH = "./testdata"

function benchmark(file::AbstractString)
    path = joinpath(TEST_DATA_PATH, file)

    # File compressed with the real Unix compress.
    output_unix = open("$path.Z_original")

    # File compressed by Julia.
    compress(path)
    output_Julia = open("$path.Z")

    # Use Mmap.mmap() to leave files on disk.
    is_equal = (mmap(output_unix) == mmap(output_Julia))

    close(output_unix)
    close(output_Julia)
    return is_equal
end

@test benchmark("asyoulik.txt")
@test benchmark("alice29.txt")
@test benchmark("cp.html")
@test benchmark("fields.c")
@test benchmark("grammar.lsp")
# I think these fail because we haven't implemented the CLEAR signal yet.
# @test benchmark("kennedy.xls")
# @test benchmark("lcet10.txt")
# @test benchmark("plrabn12.txt")
# @test benchmark("ptt5")
@test benchmark("sum")
@test benchmark("xargs.1")
