// Decompile functions to C and list their callees.
// Args: <out file> <depth> <addr|name> [...]   (addr may be "space::hex" for overlays)
// Creates a function at a bare label when none exists.
// depth 0 dumps only the given functions; depth N follows callees N levels.
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.HashSet;
import java.util.Set;

public class Decomp extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        int depth = Integer.parseInt(a[1]);
        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        StringBuilder out = new StringBuilder();
        ArrayDeque<Object[]> q = new ArrayDeque<>();
        Set<Function> seen = new HashSet<>();
        for (int i = 2; i < a.length; i++) {
            ghidra.program.model.address.Address at = currentProgram.getAddressFactory().getAddress(a[i]);
            Function f = at != null ? getFunctionContaining(at) : null;
            if (f == null && !getGlobalFunctions(a[i]).isEmpty()) f = getGlobalFunctions(a[i]).get(0);
            if (f == null && at != null) { disassemble(at); f = createFunction(at, null); }
            if (f == null) { out.append("// no function at ").append(a[i]).append('\n'); continue; }
            q.add(new Object[]{f, 0});
        }
        while (!q.isEmpty()) {
            Object[] e = q.poll();
            Function f = (Function) e[0];
            int d = (Integer) e[1];
            if (!seen.add(f)) continue;
            DecompileResults r = di.decompileFunction(f, 60, monitor);
            out.append("// ===== ").append(f.getName()).append(" @ ").append(f.getEntryPoint())
               .append(" depth ").append(d).append('\n');
            out.append(r.decompileCompleted() ? r.getDecompiledFunction().getC() : "// FAILED " + r.getErrorMessage() + "\n");
            StringBuilder callees = new StringBuilder("// callees:");
            for (Function c : f.getCalledFunctions(monitor)) {
                callees.append(' ').append(c.getName());
                if (d < depth && (c.getName().startsWith("FUN_") || c.getName().equals("main")))
                    q.add(new Object[]{c, d + 1});
            }
            out.append(callees).append("\n\n");
        }
        Files.writeString(Path.of(a[0]), out.toString());
    }
}
