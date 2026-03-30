module UnixCompress

export compress
export decompress
export uncompress # Alias for decompress

const CLEAR_CODE = UInt16(256)
const INIT_CODE_LENGTH = 9

include("compress.jl")
include("decompress.jl")

end # module UnixCompress
