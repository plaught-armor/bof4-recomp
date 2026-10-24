// List every function: address space, entry, body start/end, name.
// Args: <out tsv>
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import java.nio.file.Files;
import java.nio.file.Path;

public class ExportFunctions extends GhidraScript {
    @Override
    public void run() throws Exception {
        StringBuilder out = new StringBuilder("space\tentry\tmin\tmax\tname\n");
        for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
            var body = f.getBody();
            out.append(f.getEntryPoint().getAddressSpace().getName()).append('\t')
               .append(Long.toHexString(f.getEntryPoint().getOffset())).append('\t')
               .append(Long.toHexString(body.getMinAddress().getOffset())).append('\t')
               .append(Long.toHexString(body.getMaxAddress().getOffset())).append('\t')
               .append(f.getName()).append('\n');
        }
        Files.writeString(Path.of(getScriptArgs()[0]), out.toString());
    }
}
