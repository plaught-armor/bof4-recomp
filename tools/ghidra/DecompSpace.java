// Decompile every function in one address space (e.g. an overlay) to C.
// Args: <out file> <space name>
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.AddressSpace;
import ghidra.program.model.listing.Function;
import java.nio.file.Files;
import java.nio.file.Path;

public class DecompSpace extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        AddressSpace sp = currentProgram.getAddressFactory().getAddressSpace(a[1]);
        if (sp == null) throw new IllegalArgumentException("no address space " + a[1]);
        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        StringBuilder out = new StringBuilder();
        for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
            if (f.getEntryPoint().getAddressSpace() != sp) continue;
            DecompileResults r = di.decompileFunction(f, 60, monitor);
            out.append("// ===== ").append(f.getName()).append(" @ ").append(f.getEntryPoint()).append('\n');
            out.append(r.decompileCompleted() ? r.getDecompiledFunction().getC() : "// failed: " + r.getErrorMessage() + "\n");
        }
        Files.writeString(Path.of(a[0]), out.toString());
    }
}
