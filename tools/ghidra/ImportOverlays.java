// Create one Ghidra overlay block per extracted BoF4 code overlay and seed its functions.
// Args: <overlays dir containing manifest.tsv>
// Overlay layout: u32 overlay id, then an optional table of u32 function pointers
// into the overlay itself; when there is no table, code starts at +4.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSpace;
import ghidra.program.model.data.DWordDataType;
import ghidra.program.model.data.PointerDataType;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.SourceType;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

public class ImportOverlays extends GhidraScript {
    @Override
    public void run() throws Exception {
        Path dir = Path.of(getScriptArgs()[0]);
        List<String> rows = Files.readAllLines(dir.resolve("manifest.tsv"));
        Memory mem = currentProgram.getMemory();
        int made = 0, seeds = 0;
        for (String row : rows.subList(1, rows.size())) {
            String[] c = row.split("\t");
            String file = c[0];
            long slot = Long.parseLong(c[1], 16);
            String name = file.substring(0, file.length() - 4);
            if (mem.getBlock(name) != null) continue;
            byte[] blob = Files.readAllBytes(dir.resolve(file));
            Address base = toAddr(slot);
            MemoryBlock b = mem.createInitializedBlock(name, base, new java.io.ByteArrayInputStream(blob),
                    blob.length, monitor, true);
            b.setRead(true); b.setWrite(true); b.setExecute(true);
            b.setSourceName(c[5]);
            AddressSpace sp = b.getStart().getAddressSpace();
            ByteBuffer bb = ByteBuffer.wrap(blob).order(ByteOrder.LITTLE_ENDIAN);
            createData(b.getStart(), DWordDataType.dataType);
            setEOLComment(b.getStart(), "overlay id(s) " + c[3]);
            long end = slot + blob.length;
            int off = 4;
            while (off + 4 <= blob.length) {
                long p = bb.getInt(off) & 0xffffffffL;
                if (p < slot + 4 || p >= end || (p & 3) != 0) break;
                Address target = sp.getAddress(p);
                createData(sp.getAddress(slot + off), PointerDataType.dataType);
                if (getFunctionAt(target) == null) {
                    disassemble(target);
                    createFunction(target, null);
                    seeds++;
                }
                off += 4;
            }
            if (off == 4) {
                disassemble(sp.getAddress(slot + 4));
                createFunction(sp.getAddress(slot + 4), null);
                seeds++;
            }
            createLabel(b.getStart(), name + "_hdr", true, SourceType.USER_DEFINED);
            made++;
        }
        println("overlays created " + made + ", function seeds " + seeds);
    }
}
