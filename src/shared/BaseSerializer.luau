--!strict
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local Types = require(ReplicatedStorage.Shared.Types)

type BuildingBlockData = Types.BuildingBlockData
type BuildingTier = Types.BuildingTier
type DefenseMountSurface = Types.DefenseMountSurface
type ModuleType = Types.ModuleType

local FORMAT_VERSION = 1
local HEADER_SIZE = 7
local BLOCK_STRIDE = 12
local COORD_STEP = 0.25
local ROT_STEP_DEG = 15
local ROT_STEPS_COUNT = 24
local MAX_BLOCKS = BuildingConfig.MaxPiecesPerBase
local INT16_MIN = -32768
local INT16_MAX = 32767
local UINT16_MAX = 65535
local DEFAULT_ORIGIN = CFrame.identity

local FLAG_CODE_LOCK = 0x01
local FLAG_DOOR_OPEN = 0x02
local FLAG_HBHF_LINKED = 0x04
local FLAG_HAS_DOOR = 0x08
local MOUNT_SHIFT = 4
local MOUNT_MASK = 0x30

local MODULE_TO_ID: { [string]: number } = {}
local ID_TO_MODULE: { [number]: ModuleType } = {}
for idx, pieceType in BuildingConfig.PieceOrder do
	MODULE_TO_ID[pieceType] = idx
	ID_TO_MODULE[idx] = pieceType
end

local LEGACY_ALIAS_TO_CANONICAL: { [string]: ModuleType } = table.freeze({
	TriangleFoundation = "triangle_foundation",
	WindowWall = "window_wall",
	TriangleFloor = "triangle_floor",
	SquareStairs = "square_stairs",
	TriangleStairs = "triangle_stairs",
})
for alias, canonical in LEGACY_ALIAS_TO_CANONICAL do
	local id = MODULE_TO_ID[canonical]
	if id ~= nil then
		MODULE_TO_ID[alias] = id
	end
end
table.freeze(MODULE_TO_ID)
table.freeze(ID_TO_MODULE)

local TIER_TO_ID: { [string]: number } = {}
local ID_TO_TIER: { [number]: BuildingTier } = {}
for idx, tierName in BuildingConfig.TierOrder do
	TIER_TO_ID[tierName] = idx
	ID_TO_TIER[idx] = tierName
end
table.freeze(TIER_TO_ID)
table.freeze(ID_TO_TIER)

local MOUNT_TO_CODE: { [string]: number } = table.freeze({
	Floor = 1,
	Wall = 2,
	Ceiling = 3,
})

local CODE_TO_MOUNT: { [number]: DefenseMountSurface } = table.freeze({
	[1] = "Floor",
	[2] = "Wall",
	[3] = "Ceiling",
})

local CRC32_TABLE: { [number]: number } = {}
for i = 0, 255 do
	local crc = i
	for _ = 1, 8 do
		if bit32.band(crc, 1) ~= 0 then
			crc = bit32.bxor(bit32.rshift(crc, 1), 0xEDB88320)
		else
			crc = bit32.rshift(crc, 1)
		end
	end
	CRC32_TABLE[i] = crc
end
table.freeze(CRC32_TABLE)

local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_ENCODE_CHARS: { [number]: string } = {}
local B64_DECODE_MAP: { [number]: number } = {}
for i = 0, 63 do
	local ch = string.sub(B64_ALPHABET, i + 1, i + 1)
	B64_ENCODE_CHARS[i] = ch
	B64_DECODE_MAP[string.byte(ch)] = i
end
table.freeze(B64_ENCODE_CHARS)
table.freeze(B64_DECODE_MAP)

local BaseSerializer = {
	DEFAULT_ORIGIN = DEFAULT_ORIGIN,
	FORMAT_VERSION = FORMAT_VERSION,
	HEADER_SIZE = HEADER_SIZE,
	BLOCK_STRIDE = BLOCK_STRIDE,
	COORD_STEP = COORD_STEP,
	ROT_STEP_DEG = ROT_STEP_DEG,
	MAX_BLOCKS = MAX_BLOCKS,
	StateFlags = table.freeze({
		CodeLock = FLAG_CODE_LOCK,
		DoorOpen = FLAG_DOOR_OPEN,
		HbhfLinked = FLAG_HBHF_LINKED,
		HasDoor = FLAG_HAS_DOOR,
	}),
}

local function computeBufferCRC32(buf: buffer, zeroOffset: number?, zeroLength: number?): number
	local len = buffer.len(buf)
	local crc = 0xFFFFFFFF
	local zStart = zeroOffset or -1
	local zEnd = if zeroOffset ~= nil and zeroLength ~= nil then (zeroOffset + zeroLength - 1) else -1
	for i = 0, len - 1 do
		local b = if i >= zStart and i <= zEnd then 0 else buffer.readu8(buf, i)
		local idx = bit32.band(bit32.bxor(crc, b), 0xFF)
		crc = bit32.bxor(bit32.rshift(crc, 8), CRC32_TABLE[idx])
	end
	return bit32.bxor(crc, 0xFFFFFFFF)
end

function BaseSerializer.ComputeCRC32(buf: buffer): number
	return computeBufferCRC32(buf, nil, nil)
end

function BaseSerializer.EncodeBase64(buf: buffer): string
	local len = buffer.len(buf)
	if len == 0 then
		return ""
	end
	local out: { string } = table.create(math.ceil(len / 3) * 4)
	local outIdx = 1
	local i = 0
	while i < len do
		local b0 = buffer.readu8(buf, i)
		local has1 = (i + 1) < len
		local has2 = (i + 2) < len
		local b1 = if has1 then buffer.readu8(buf, i + 1) else 0
		local b2 = if has2 then buffer.readu8(buf, i + 2) else 0
		local triple = bit32.bor(bit32.lshift(b0, 16), bit32.lshift(b1, 8), b2)

		out[outIdx] = B64_ENCODE_CHARS[bit32.band(bit32.rshift(triple, 18), 0x3F)]
		out[outIdx + 1] = B64_ENCODE_CHARS[bit32.band(bit32.rshift(triple, 12), 0x3F)]
		out[outIdx + 2] = if has1 then B64_ENCODE_CHARS[bit32.band(bit32.rshift(triple, 6), 0x3F)] else "="
		out[outIdx + 3] = if has2 then B64_ENCODE_CHARS[bit32.band(triple, 0x3F)] else "="
		outIdx += 4
		i += 3
	end
	return table.concat(out)
end

function BaseSerializer.DecodeBase64(encoded: string): buffer?
	if type(encoded) ~= "string" then
		return nil
	end
	local len = #encoded
	if len == 0 then
		return buffer.create(0)
	end
	if len % 4 ~= 0 then
		return nil
	end

	local padding = 0
	if string.sub(encoded, len, len) == "=" then
		padding += 1
	end
	if string.sub(encoded, len - 1, len - 1) == "=" then
		padding += 1
	end

	local outLen = (len // 4) * 3 - padding
	if outLen < 0 then
		return nil
	end

	local buf = buffer.create(outLen)
	local outIdx = 0
	for i = 1, len, 4 do
		local c0 = string.byte(encoded, i)
		local c1 = string.byte(encoded, i + 1)
		local c2 = string.byte(encoded, i + 2)
		local c3 = string.byte(encoded, i + 3)

		local v0 = B64_DECODE_MAP[c0]
		local v1 = B64_DECODE_MAP[c1]
		if v0 == nil or v1 == nil then
			return nil
		end

		local isLastGroup = (i + 3) == len
		local v2: number? = nil
		local v3: number? = nil

		if c2 == 61 then
			if not isLastGroup or c3 ~= 61 then
				return nil
			end
			v2 = 0
			v3 = 0
		else
			v2 = B64_DECODE_MAP[c2]
			if v2 == nil then
				return nil
			end
			if c3 == 61 then
				if not isLastGroup then
					return nil
				end
				v3 = 0
			else
				v3 = B64_DECODE_MAP[c3]
				if v3 == nil then
					return nil
				end
			end
		end

		local triple =
			bit32.bor(bit32.lshift(v0, 18), bit32.lshift(v1, 12), bit32.lshift(v2 :: number, 6), v3 :: number)
		if outIdx < outLen then
			buffer.writeu8(buf, outIdx, bit32.band(bit32.rshift(triple, 16), 0xFF))
			outIdx += 1
		end
		if outIdx < outLen then
			buffer.writeu8(buf, outIdx, bit32.band(bit32.rshift(triple, 8), 0xFF))
			outIdx += 1
		end
		if outIdx < outLen then
			buffer.writeu8(buf, outIdx, bit32.band(triple, 0xFF))
			outIdx += 1
		end
	end

	return buf
end

local function quantizeCoord(value: number): number
	if not Types.IsFiniteNumber(value) then
		return 0
	end
	local q = math.floor((value / COORD_STEP) + 0.5)
	return math.clamp(q, INT16_MIN, INT16_MAX)
end

local function normalizeYawDeg(deg: number): number
	local mod = deg % 360
	return if mod < 0 then mod + 360 else mod
end

local function extractYawDeg(cf: CFrame): number
	local _, yRad, _ = cf:ToOrientation()
	return normalizeYawDeg(math.deg(yRad))
end

local function buildStateMask(block: BuildingBlockData): number
	local mask = 0
	if block.HasCodeLock == true then
		mask = bit32.bor(mask, FLAG_CODE_LOCK)
	end
	if block.IsDoorOpen == true then
		mask = bit32.bor(mask, FLAG_DOOR_OPEN)
	end
	if block.LinkedHbhfSensor == true then
		mask = bit32.bor(mask, FLAG_HBHF_LINKED)
	end
	if block.HasDoor == true then
		mask = bit32.bor(mask, FLAG_HAS_DOOR)
	end
	local mountCode = if type(block.MountSurface) == "string" then MOUNT_TO_CODE[block.MountSurface] else nil
	if mountCode ~= nil then
		mask = bit32.bor(mask, bit32.lshift(mountCode, MOUNT_SHIFT))
	end
	return mask
end

function BaseSerializer.PackBuffer(blocks: { BuildingBlockData }, originCFrame: CFrame?): buffer
	local originCF = originCFrame or DEFAULT_ORIGIN
	local validBlocks: { { Block: BuildingBlockData, ModuleId: number, TierId: number } } = {}

	for _, block in blocks do
		if #validBlocks >= MAX_BLOCKS then
			break
		end
		if
			type(block) == "table"
			and type(block.PieceType) == "string"
			and Types.IsFiniteNumber(block.PosX)
			and Types.IsFiniteNumber(block.PosY)
			and Types.IsFiniteNumber(block.PosZ)
		then
			local moduleId = MODULE_TO_ID[block.PieceType]
			if moduleId ~= nil then
				local canonical = ID_TO_MODULE[moduleId]
				local pieceCfg = BuildingConfig.Pieces[canonical]
				if pieceCfg ~= nil then
					local tierName: string = if type(block.Tier) == "string"
							and TIER_TO_ID[block.Tier] ~= nil
							and pieceCfg.Upgradeable
						then block.Tier
						else "wood"
					local tierId = TIER_TO_ID[tierName] or 1
					table.insert(validBlocks, {
						Block = block,
						ModuleId = moduleId,
						TierId = tierId,
					})
				end
			end
		end
	end

	local count = #validBlocks
	local buf = buffer.create(HEADER_SIZE + count * BLOCK_STRIDE)
	buffer.writeu8(buf, 0, FORMAT_VERSION)
	buffer.writeu16(buf, 1, count)
	buffer.writeu32(buf, 3, 0)

	for i = 1, count do
		local entry = validBlocks[i]
		local block = entry.Block
		local offset = HEADER_SIZE + (i - 1) * BLOCK_STRIDE

		local worldRotY = if Types.IsFiniteNumber(block.RotY) then block.RotY else 0
		local worldPos = Vector3.new(block.PosX, block.PosY, block.PosZ)
		local localPos = originCF:PointToObjectSpace(worldPos)
		local worldCF = CFrame.new(worldPos) * CFrame.Angles(0, math.rad(worldRotY), 0)
		local relCF = originCF:ToObjectSpace(worldCF)
		local relDeg = extractYawDeg(relCF)
		local rotStep = math.floor((relDeg / ROT_STEP_DEG) + 0.5) % ROT_STEPS_COUNT

		local hpVal = if Types.IsFiniteNumber(block.Hp) then math.floor(block.Hp + 0.5) else 0
		local clampedHp = math.clamp(hpVal, 0, UINT16_MAX)
		local stateMask = buildStateMask(block)

		buffer.writei16(buf, offset + 0, quantizeCoord(localPos.X))
		buffer.writei16(buf, offset + 2, quantizeCoord(localPos.Y))
		buffer.writei16(buf, offset + 4, quantizeCoord(localPos.Z))
		buffer.writeu8(buf, offset + 6, rotStep)
		buffer.writeu8(buf, offset + 7, entry.ModuleId)
		buffer.writeu8(buf, offset + 8, entry.TierId)
		buffer.writeu16(buf, offset + 9, clampedHp)
		buffer.writeu8(buf, offset + 11, stateMask)
	end

	local checksum = computeBufferCRC32(buf, 3, 4)
	buffer.writeu32(buf, 3, checksum)
	return buf
end

function BaseSerializer.UnpackBuffer(buf: buffer, originCFrame: CFrame?): (boolean, { BuildingBlockData } | string)
	if typeof(buf) ~= "buffer" then
		return false, "Invalid buffer argument"
	end
	local totalLen = buffer.len(buf)
	if totalLen < HEADER_SIZE then
		return false, "Truncated header"
	end

	local version = buffer.readu8(buf, 0)
	if version ~= FORMAT_VERSION then
		return false, string.format("Unsupported BaseSerializer format version: %d", version)
	end

	local count = buffer.readu16(buf, 1)
	if count > MAX_BLOCKS then
		return false, string.format("Block count %d exceeds MaxBlocks (%d)", count, MAX_BLOCKS)
	end

	local expectedLen = HEADER_SIZE + count * BLOCK_STRIDE
	if totalLen ~= expectedLen then
		return false, string.format("Buffer size mismatch: got %d bytes, expected %d", totalLen, expectedLen)
	end

	local storedChecksum = buffer.readu32(buf, 3)
	local computedChecksum = computeBufferCRC32(buf, 3, 4)
	if storedChecksum ~= computedChecksum then
		return false, string.format("CRC32 mismatch (stored=%u, computed=%u)", storedChecksum, computedChecksum)
	end

	local originCF = originCFrame or DEFAULT_ORIGIN
	local blocks: { BuildingBlockData } = table.create(count)

	for i = 1, count do
		local offset = HEADER_SIZE + (i - 1) * BLOCK_STRIDE
		local qx = buffer.readi16(buf, offset + 0)
		local qy = buffer.readi16(buf, offset + 2)
		local qz = buffer.readi16(buf, offset + 4)
		local rotStep = buffer.readu8(buf, offset + 6)
		local moduleId = buffer.readu8(buf, offset + 7)
		local tierId = buffer.readu8(buf, offset + 8)
		local rawHp = buffer.readu16(buf, offset + 9)
		local stateMask = buffer.readu8(buf, offset + 11)

		local moduleType = ID_TO_MODULE[moduleId]
		if moduleType == nil then
			return false, string.format("Unknown module id %d at index %d", moduleId, i)
		end
		local pieceCfg = BuildingConfig.Pieces[moduleType]
		if pieceCfg == nil then
			return false, string.format("Missing config for module '%s' at index %d", moduleType, i)
		end

		local tier = ID_TO_TIER[tierId]
		if tier == nil then
			return false, string.format("Unknown tier id %d at index %d", tierId, i)
		end
		if not pieceCfg.Upgradeable then
			tier = "wood"
		end

		local tierCfg = BuildingConfig.Tiers[tier]
		local maxHp = math.floor(pieceCfg.BaseHp * tierCfg.HpMultiplier + 0.5)
		local hp = if rawHp == 0 then maxHp else math.clamp(rawHp, 1, maxHp)

		local localPos = Vector3.new(qx * COORD_STEP, qy * COORD_STEP, qz * COORD_STEP)
		local relDeg = (rotStep % ROT_STEPS_COUNT) * ROT_STEP_DEG
		local worldCF = originCF * CFrame.new(localPos) * CFrame.Angles(0, math.rad(relDeg), 0)
		local worldDeg = extractYawDeg(worldCF)
		local snappedRotY = (math.floor((worldDeg / ROT_STEP_DEG) + 0.5) * ROT_STEP_DEG) % 360

		local mountCode = bit32.rshift(bit32.band(stateMask, MOUNT_MASK), MOUNT_SHIFT)
		local mountSurface = CODE_TO_MOUNT[mountCode]

		local hasCodeLock = bit32.band(stateMask, FLAG_CODE_LOCK) ~= 0
		local isDoorOpen = bit32.band(stateMask, FLAG_DOOR_OPEN) ~= 0
		local linkedHbhf = bit32.band(stateMask, FLAG_HBHF_LINKED) ~= 0
		local hasDoor = bit32.band(stateMask, FLAG_HAS_DOOR) ~= 0

		table.insert(blocks, {
			Uid = HttpService:GenerateGUID(false),
			PieceType = moduleType,
			Tier = tier,
			PosX = worldCF.Position.X,
			PosY = worldCF.Position.Y,
			PosZ = worldCF.Position.Z,
			RotY = snappedRotY,
			ParentUid = nil,
			AnchorUid = nil,
			SocketId = nil,
			MountSurface = mountSurface,
			Hp = hp,
			LastDamagedAt = 0,
			Storage = if pieceCfg.StorageSlots ~= nil then {} else nil,
			HasCodeLock = if hasCodeLock then true else nil,
			IsDoorOpen = if isDoorOpen then true else nil,
			LinkedHbhfSensor = if linkedHbhf then true else nil,
			HasDoor = if hasDoor then true else nil,
		})
	end

	return true, blocks
end

function BaseSerializer.SerializeBase(blocks: { BuildingBlockData }, originCFrame: CFrame?): string
	local buf = BaseSerializer.PackBuffer(blocks, originCFrame)
	return BaseSerializer.EncodeBase64(buf)
end

function BaseSerializer.DeserializeBase(
	encoded: string,
	originCFrame: CFrame?
): (boolean, { BuildingBlockData } | string)
	if type(encoded) ~= "string" or #encoded == 0 then
		return false, "Empty encoded base string"
	end
	local buf = BaseSerializer.DecodeBase64(encoded)
	if buf == nil then
		return false, "Malformed Base64 payload"
	end
	return BaseSerializer.UnpackBuffer(buf, originCFrame)
end

return BaseSerializer
