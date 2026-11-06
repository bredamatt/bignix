# bignix

A `nix-shell` based development environment for bigraph modelling


## Instructions


You need `nix` installed on your machine. After that, should be as simple as:

```
nix-shell
```

This will build all dependencies and place them in the `nix-shell` PATH.

## References for Bigraph and BigraphER

- [Robin Milner. *The space and motion of communicating agents*. Cambridge
University Press (2009).][milner]
- [Michele Sevegnani and Muffy Calder. *Bigraphs with sharing*. Theoretical
Computer Science 577 (2015): 43-73.][share]
- [Michele Sevegnani and Muffy Calder. *BigraphER: rewriting and analysis engine for bigraphs*. Proceedings of Computer Aided Verification (CAV 2016), Lecture Notes in Computer Science 9780 (2016): 494-501.][tech]
- [T. Bray Ed. *The JavaScript Object Notation (JSON) Data Interchange Format*. (2014)][json]
- [OPAM: OCaml package manager][opam]
- [PRISM: probabilistic model checker][prism]
- [MiniSAT: a minimalistic and high-performance SAT solver][minisat]
- [MiniCARD cardinality solver][minicard]
- [Glasgow Subgraph Solver][gbs]

[milner]:  <http://dl.acm.org/citation.cfm?id=1540607> "Robin Milner. *The space and motion of communicating agents*. Cambridge University Press (2009)."
[share]:   <http://doi.org/10.1016/j.tcs.2015.02.011> "Michele Sevegnani and Muffy Calder. *Bigraphs with sharing*. Theoretical Computer Science 577 (2015): 43-73."
[tech]:    <http://doi.org/10.1007/978-3-319-41540-6_27> "Michele Sevegnani and Muffy Calder. *BigraphER: rewriting and analysis engine for bigraphs*. Proceedings of Computer Aided Verification (CAV 2016), Lecture Notes in Computer Science 9780 (2016): 494-501"
[json]:    <http://tools.ietf.org/html/rfc7159>
"T. Bray Ed. The JavaScript Object Notation (JSON) Data Interchange Format, 2014"
[prism]:   <http://www.prismmodelchecker.org/> "PRISM: probabilistic model checker"
[minisat]: <https://github.com/niklasso/minisat> "MiniSAT: a minimalistic and high-performance SAT solver"
[minicard]: <https://github.com/liffiton/minicard> "MiniCARD is a cardinality solver based on MiniSAT"
[opam]:    <https://opam.ocaml.org/> "OPAM: OCaml package manager"
[gbs]: <https://github.com/ciaranm/glasgow-subgraph-solver> "Glasgow Subgraph Solver"