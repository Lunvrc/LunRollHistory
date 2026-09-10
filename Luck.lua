-- LunRollHistory :: Luck.lua
-- Turns the roll history into a luck rating.
--
-- Two independent questions get asked of every player:
--   1. Are their roll numbers high?  A /roll is uniform over 1..100, so the
--      mean of n rolls has a known distribution and a real z-score.
--   2. Do they win more than their share?  In a contest between k players each
--      has a 1/k chance, so expected wins is the sum of those fractions.
-- Both are turned into z-scores, which is what makes small and large sample
-- sizes comparable: 60 average over 4 rolls is noise, over 400 it is not.

local ADDON, ns = ...

local Luck = {}
ns.Luck = Luck

Luck.MIN_ROLLS = 5              -- below this the numbers are meaningless
Luck.ROLL_MEAN = 50.5           -- mean of a discrete uniform 1..100
Luck.ROLL_SD   = 28.8661        -- sqrt((100^2 - 1) / 12)

--------------------------------------------------------------------------------
-- Normal distribution
--------------------------------------------------------------------------------
-- Abramowitz and Stegun 7.1.26. Max absolute error around 1.5e-7, which is far
-- finer than anything we display.
local function Erf(x)
    local sign = (x < 0) and -1 or 1
    x = math.abs(x)
    local a1, a2, a3, a4, a5 = 0.254829592, -0.284496736, 1.421413741,
                               -1.453152027, 1.061405429
    local p = 0.3275911
    local t = 1 / (1 + p * x)
    local y = 1 - ((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t * math.exp(-x * x)
    return sign * y
end

local function NormalCDF(z)
    return 0.5 * (1 + Erf(z / math.sqrt(2)))
end
Luck.NormalCDF = NormalCDF

--------------------------------------------------------------------------------
-- Aggregation
--------------------------------------------------------------------------------
local function IsRealRoll(r)
    return r.name and r.roll and r.roll > 0
        and r.state ~= "Pass" and r.state ~= "NoRoll"
end

-- Returns an array of per-player records, sorted luckiest first, plus a lookup
-- by name.
function Luck:Compute()
    local db = LunRollHistoryDB
    local byName, order = {}, {}
    if not db then return order, byName end

    local function Record(name, class)
        local rec = byName[name]
        if not rec then
            rec = { name = name, class = class, rolls = 0, rollSum = 0,
                    contests = 0, wins = 0, expWins = 0, expVar = 0, items = 0,
                    received = 0 }
            byName[name] = rec
            order[#order + 1] = rec
        end
        if class and not rec.class then rec.class = class end
        return rec
    end

    for i = 1, #db.log do
        local e = db.log[i]
        if e.t == "drop" and type(e.rolls) == "table" then
            local contenders = {}
            for j = 1, #e.rolls do
                local r = e.rolls[j]
                if IsRealRoll(r) then contenders[#contenders + 1] = r end
            end

            local k = #contenders
            for _, r in ipairs(contenders) do
                local rec = Record(r.name, r.class)
                rec.rolls = rec.rolls + 1
                rec.rollSum = rec.rollSum + r.roll
                rec.items = rec.items + 1

                -- An uncontested drop is a guaranteed win and says nothing
                -- about luck, so it is left out of the win model entirely.
                if k > 1 then
                    local p = 1 / k
                    rec.contests = rec.contests + 1
                    rec.expWins = rec.expWins + p
                    rec.expVar = rec.expVar + p * (1 - p)
                    if r.winner then rec.wins = rec.wins + 1 end
                end
            end
        end
    end

    -- Items the loot log says actually reached the player. This is a separate
    -- observation from winning a roll: it also catches items handed over in
    -- trade, and it misses anything the quality filter dropped. It is reported
    -- alongside the rating rather than folded into it, because there is no
    -- denominator for "items received" the way there is for "rolls won".
    for i = 1, #db.log do
        local e = db.log[i]
        if e.t == "loot" and e.name then
            local rec = byName[e.name]
            if rec then rec.received = rec.received + 1 end
        end
    end

    for _, rec in ipairs(order) do
        rec.enough = rec.rolls >= self.MIN_ROLLS
        rec.avgRoll = (rec.rolls > 0) and (rec.rollSum / rec.rolls) or 0

        if rec.rolls > 0 then
            rec.rollZ = (rec.avgRoll - self.ROLL_MEAN)
                      / (self.ROLL_SD / math.sqrt(rec.rolls))
            rec.rollPct = NormalCDF(rec.rollZ) * 100
        end

        if rec.expVar > 0 then
            rec.winZ = (rec.wins - rec.expWins) / math.sqrt(rec.expVar)
            rec.winPct = NormalCDF(rec.winZ) * 100
        end

        -- Plain mean of the available z-scores. Rolling high and winning are
        -- correlated, so treating them as independent and dividing by sqrt(2)
        -- would overstate the result. The mean errs the other way, which is
        -- the right direction to err when the output is "you are unlucky".
        local zs, sum = 0, 0
        if rec.rollZ then zs, sum = zs + 1, sum + rec.rollZ end
        if rec.winZ then zs, sum = zs + 1, sum + rec.winZ end
        rec.z = (zs > 0) and (sum / zs) or 0
        rec.luck = NormalCDF(rec.z) * 100
    end

    table.sort(order, function(a, b)
        if a.enough ~= b.enough then return a.enough end
        return (a.z or 0) > (b.z or 0)
    end)

    -- Rank against the other tracked players, which is a different question
    -- from the rating itself: everyone in a group can be unlucky at once.
    local ranked = {}
    for _, rec in ipairs(order) do
        if rec.enough then ranked[#ranked + 1] = rec end
    end
    for i, rec in ipairs(ranked) do
        rec.rank = i
        rec.rankOf = #ranked
    end

    -- Percentile against the other tracked players, per metric. The displayed
    -- numbers all say "than X% of players", so they need to mean that: a
    -- headline computed against chance sitting next to a caption computed
    -- against headcount is two different measurements wearing one label.
    local function PeerPercentile(key, out)
        local n = #ranked
        if n < 2 then return end
        for _, rec in ipairs(ranked) do
            local mine = rec[key]
            if mine then
                local below, ties = 0, 0
                for _, other in ipairs(ranked) do
                    if other ~= rec and other[key] then
                        if other[key] < mine then below = below + 1
                        elseif other[key] == mine then ties = ties + 1 end
                    end
                end
                rec[out] = (below + ties * 0.5) / (n - 1) * 100
            end
        end
    end

    -- The rating ranks on z, which accounts for sample size: 70 across sixty
    -- rolls beats 70 across six. The Average roll row ranks on the raw average
    -- instead, because that is the number printed beside it and a row labelled
    -- "Average roll" comparing something other than averages is a trap.
    PeerPercentile("z", "peerLuck")
    PeerPercentile("avgRoll", "peerRoll")
    PeerPercentile("winZ", "peerWin")

    return order, byName
end

-- The character the user is actually playing, if they appear in the history.
function Luck:DefaultPlayer(byName)
    local ok, name = pcall(UnitName, "player")
    if ok and name and byName[name] then return name end
    return nil
end
