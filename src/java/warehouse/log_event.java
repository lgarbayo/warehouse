package warehouse;

import jason.asSemantics.DefaultInternalAction;
import jason.asSemantics.TransitionSystem;
import jason.asSemantics.Unifier;
import jason.asSyntax.StringTerm;
import jason.asSyntax.Term;

import java.io.BufferedWriter;
import java.io.FileWriter;

/**
 * Internal action: warehouse.log_event(Arg1, Arg2, ...)
 * Concatenates all args and appends the resulting line to events.log.
 * Drop-in replacement for .print("EVENT | ...") calls.
 */
public class log_event extends DefaultInternalAction {

    private static final String LOG_FILE = "events.log";
    private static final Object LOCK = new Object();

    @Override
    public Object execute(TransitionSystem ts, Unifier un, Term[] args) throws Exception {
        StringBuilder sb = new StringBuilder();
        for (Term t : args) {
            if (t instanceof StringTerm) {
                sb.append(((StringTerm) t).getString());
            } else {
                sb.append(t.toString());
            }
        }
        String line = sb.toString();

        synchronized (LOCK) {
            try (BufferedWriter bw = new BufferedWriter(new FileWriter(LOG_FILE, true))) {
                bw.write(line);
                bw.newLine();
            }
        }
        return true;
    }
}
