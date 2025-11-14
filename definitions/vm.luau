local vm = {}

function vm.create(path: string): { [any]: any }
	error("not implemented")
end

function vm.gcstop()
	error("not implemented")
end

function vm.gcrestart()
	error("not implemented")
end

function vm.gccollect()
	error("not implemented")
end

function vm.gccount(): number
	error("not implemented")
end

function vm.gcisrunning(): boolean
	error("not implemented")
end

return vm
