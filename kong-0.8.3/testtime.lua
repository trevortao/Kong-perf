--require "socket"
--local tbl = loadstring(os.date("return {day=%d, month=%m, year=%Y, sec=0, min=0, hour=0}"))()
--print(os.time(tbl))
--print("Milliseconds: " .. socket.gettime()*1000)

local x = os.clock()
local s = 0
for i=1,3000000 do s = s + i end
print(string.format("elapsed time: %.2f\n", os.clock() - x))
