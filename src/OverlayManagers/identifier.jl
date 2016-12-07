const COOKIE_LEN = 16  # We can only 16-characters worth of data. Should match Base.HDR_COOKIE_LEN

function overlay_id(node_id::Integer, cookie::String)
    oid = zero(UInt128)

    # Add each character of the cookie as a 6-bit value (16 characters = 96-bits)
    assert(length(cookie) == COOKIE_LEN)
    for (i, char) in enumerate(cookie)
        val = alpha_numeric(char)
        oid |= UInt128(val) << (i - 1) * 6
    end

    # Add the final 32-bits which represent the node_id
    oid = (oid << 32) | UInt32(node_id)

    return oid
end

function cluster_cookie(oid::OverlayID)
    val = oid >> 32  # Remove the node_id

    cookie = Vector{Char}(COOKIE_LEN)
    for i in 1:COOKIE_LEN
        cookie[i] = alpha_numeric(UInt8(val & 0x3f))  # 6-bit mask
        val = val >> 6
    end

    return String(cookie)
end

function node_id(oid::OverlayID)
    UInt32(oid & (2^32 - 1))
end


const DIGIT_OFFSET = 0
const UPPER_OFFSET = ('9' - '0' + 1) + DIGIT_OFFSET
const LOWER_OFFSET = ('Z' - 'A' + 1) + UPPER_OFFSET
const SPACE_OFFSET = ('z' - 'a' + 1) + LOWER_OFFSET


function alpha_numeric(char::Char)
    # Note: we only need 6-bits of storage and have room for 1 more char.
    local val::UInt8

    if '0' <= char <= '9'
        val = char - '0' + DIGIT_OFFSET
    elseif 'A' <= char <= 'Z'
        val = char - 'A' + UPPER_OFFSET
    elseif 'a' <= char <= 'z'
        val = char - 'a' + LOWER_OFFSET
    elseif char == ' '
        val = SPACE_OFFSET
    else
        error("Unable to convert char: '$char'")
    end

    return val
end


function alpha_numeric(val::UInt8)
    if 0 <= (val - DIGIT_OFFSET) <= 9
        char = '0' + val - DIGIT_OFFSET
    elseif 0 <= (val - UPPER_OFFSET) <= 25
        char = 'A' + val - UPPER_OFFSET
    elseif 0 <= (val - LOWER_OFFSET) <= 25
        char = 'a' + val - LOWER_OFFSET
    elseif val == SPACE_OFFSET
        char = ' '
    else
        error("Unable to convert UInt8 outside of supported range")
    end

    return char
end
