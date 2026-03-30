module UnixCompress

export compress
export decompress

# TO DO:
# - Add docs.

const CLEAR_CODE = UInt16(256)
const INIT_CODE_LENGTH = 9

include("compress.jl")
include("decompress.jl")

end # module UnixCompress
