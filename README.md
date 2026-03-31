# UnixCompress.jl

A pure Julia implementation of the Unix `compress` and `uncompress` utilities, using the LZW (Lempel–Ziv–Welch) compression algorithm.

## Installation

Package has to be developed locally, as it is not available in the Julia registry yet.

```julia
using Pkg
Pkg.dev("UnixCompress")
```

## Usage

Compress a file (creates `input.txt.Z`):

```julia
compress("input.txt")
```

Compress with a custom output path:

```julia
compress("input.txt", "output.Z")
```

Compress with non-default max code length:

```julia
compress("input.txt"; max_code_length = 14)
```

Compress from one IO to another:

```julia
input = open("input.txt", "r")
output = open("output.Z", "w")
compress(input, output)
close(input)
close(output)
```

Compress bytes:

```julia
data = Vector{UInt8}("Hello, world!")
compressed = compress(data)
```

Decompression works analogously, using the `decompress` function (alias `uncompress`).

## Performance

Both compression and decompression have received a moderate amount of attention to improve performance. Compression of `test/testdata/kennedy.xls` takes around 50 ms on my old ThinkCentre. Can we make it faster? Probably. Pull requests welcome.
