// List functions that write into a RAM range, with the written addresses.
// Args: <out file> <lo hex> <hi hex>   (hi exclusive; default RAM space)
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.TreeMap;
import java.util.TreeSet;

public class WritersOf extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        long lo = Long.parseLong(a[1], 16), hi = Long.parseLong(a[2], 16);
        TreeMap<String, TreeSet<String>> by = new TreeMap<>();
        for (long x = lo; x < hi; x++) {
            Address at = toAddr(x);
            for (Reference r : getReferencesTo(at)) {
                String kind = r.getReferenceType().isWrite() ? "W" : r.getReferenceType().isRead() ? "R" : "?";
                Function f = getFunctionContaining(r.getFromAddress());
                String key = (f == null ? "none" : f.getName() + "@" + f.getEntryPoint()) ;
                by.computeIfAbsent(key, k -> new TreeSet<>()).add(kind + Long.toHexString(x));
            }
        }
        StringBuilder out = new StringBuilder();
        for (var e : by.entrySet()) out.append(e.getKey()).append(' ').append(e.getValue()).append('\n');
        Files.writeString(Path.of(a[0]), out.toString());
    }
}
