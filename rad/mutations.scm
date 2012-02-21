;;;
;;; Stream Mutations
;;;

(define-library (rad mutations)

   (import 
      (owl base)
      (rad shared))

   (export 
      *mutations*
      default-mutations
      string->mutator)

   (begin

      ;; val++ in ff, or insert 1
      (define (inc ff key)
         (let ((val (getf ff key)))
            (if val
               (fupd ff key (+ val 1))
               (put ff key 1))))

      ;; (byte ...) bvec-ll → (bvec .. . bvec-ll)
      (define (flush-bvecs byte-list tail)
         (let loop ((len (length byte-list)) (lst byte-list))
            (if (< len avg-block-size)
                (cons (list->byte-vector lst) tail)
                (let
                  ((hd (take lst avg-block-size))
                   (tl (drop lst avg-block-size)))
                  (cons (list->byte-vector hd)
                     (loop (- len avg-block-size) tl))))))

      ;; clone a byte vector to a list and edit at given position (using primops since this is heavily used)
      (define (edit-byte-vector bvec edit-pos fn)
         (let ((len (sizeb bvec)))
            (if (eq? len 0)
               bvec
               (let loop ((pos (- len 1)) (out null))
                  (let ((val (refb bvec pos)))
                     (if (eq? pos edit-pos)
                        (if (eq? pos 0)
                           (list->byte-vector (fn val out))
                           (lets ((pos _ (fx- pos 1)))
                              (loop pos (fn val out))))
                        (if (eq? pos 0)
                           (list->byte-vector (cons val out))
                           (lets ((pos _ (fx- pos 1)))
                              (loop pos (cons val out))))))))))

      (define funny-unicode
         (list->tuple
            (append
               (list ;; some manual ones
                  (list 239 191 191)     ;; 65535
                  (list 240 144 128 128) ;; 65536
                  (list #xef #xbb #xbf)  ;; the canonical utf8 bom
                  (list #xfe #xff)       ;; utf16 be bom
                  (list #xff #xfe)       ;; utf16 le bom
                  (list 0 0 #xff #xff)   ;; ascii null be
                  (list #xff #xff 0 0)   ;; ascii null le
                  (list 43 47 118 56)    ;; and some others from wikipedia
                  (list 43 47 118 57) (list 43 47 118 43) (list 43 47 118 47)
                  (list 247 100 76) (list 221 115 102 115) (list 14 254 255) (list 251 238 40)
                  (list 251 238 40 255) (list 132 49 149 51))
               (map ;; some valid points and ranges
                  (λ (codepoint)
                     (render (list->string (list codepoint)) null)) ;; <- make UTF-8 repr
                  (fold
                  (λ (tl node)
                        (if (pair? node) ;; inclusive range
                           (append (iota (car node) 1 (+ (cdr node) 1)) tl)
                           (cons node tl)))
                     null
                     '((#x0009 . #x000d) #x00a0 #x1680 #x180e (#x2000 . #x200a) #x2028 #x2029 #x202f #x205f
                       #x3000 (#x200e . #x200f) (#x202a . #x202e) (#x200c . #x200d) #x0345 #x00b7 (#x02d0 . #x02d1)
                       #xff70 (#x02b0 . #x02b8) #xfdd0 #x034f (#x115f . #x1160) (#x2065 . #x2069) #x3164 #xffa0
                       #xe0001 (#xe0020 . #xe007f) (#x0e40 . #x0e44) #x1f4a9))))))


      ;;;
      ;;; Number Mutator
      ;;;

      (define (digit-val d)
         (cond
            ((lesser? d 48) #false)
            ((lesser? 57 d) #false)
            (else (- d 48))))

      ; → digit|F tail 
      (define (get-num lst)
         (let loop ((lst lst) (n 0) (digits 0))
            (cond
               ((null? lst)
                  (if (eq? digits 0)
                     (values #false null)
                     (values n null)))
               ((digit-val (car lst)) =>
                  (λ (d) (loop (cdr lst) (+ d (* n 10)) (+ digits 1))))
               ((eq? digits 0)
                  (values #false lst))
               (else
                  (values n lst)))))

      ;; copy from pos up to end (not countin it)
      (define (copy-range pos end tail)
         (if (eq? pos end)
            tail
            (cons (car pos) (copy-range (cdr pos) end tail))))

      ;; fixme: simple placeholder
      (define (mutate-num rs num)
         (lets ((rs n (rand rs 16)))
            (cond
               ((eq? n 0)  (values rs (+ n 1)))
               ((eq? n 1)  (values rs (- n 1)))
               ((eq? n 2)  (values rs 0)) ;; todo, pack funny nums to a list and reduce opts
               ((eq? n 3)  (values rs 1))
               ((eq? n 4)  (values rs #xff))
               ((eq? n 5)  (values rs #x100))
               ((eq? n 6)  (values rs #xffff))
               ((eq? n 7)  (values rs #x10000))
               ((eq? n 8)  (values rs #x7fffffff))
               ((eq? n 9)  (values rs #x80000000))
               ((eq? n 10) (values rs #xffffffff)) ;; todo 64-bit also when using a list
               ((eq? n 11) (values rs #x100000000))
               ((eq? n 12)
                  (lets ((rs m (rand rs (* n 2))))
                     (values rs (- n m))))
               (else  
                  (lets
                     ((rs n (rand-range rs 1 129))
                      (rs n (rand-log rs n)))
                     (values rs (+ num n)))))))

      (define (mutate-a-num rs lst nfound)
         (if (null? lst)
            (lets ((rs which (rand rs nfound)))
               ;; choose which to mutate (or 0 if none)
               (values rs which null))
            (lets ((valp lstp (get-num lst)))
               (if valp
                  (lets ((rs which tail (mutate-a-num rs lstp (+ nfound 1))))
                     (if (eq? which 0) ;; i won
                        (lets
                           ((rs new (mutate-num rs valp))
                            (new-lst (render new tail)))
                           (values rs -1 (render new tail)))
                        (values rs (- which 1)
                           (copy-range lst lstp tail))))
                  (lets ((rs which tail (mutate-a-num rs (cdr lst) nfound)))
                     (values rs which (cons (car lst) tail)))))))

      (define (sed-num rs ll meta) ;; edit a number
         (lets
            ((lst (vec->list (car ll)))
             (rs n lst (mutate-a-num rs lst 0))
             (lst (flush-bvecs lst (cdr ll))))
            (values sed-num rs lst (inc meta 'muta-num) 0)))


      ;;;
      ;;; Byte-level Mutations
      ;;;

      (define (sed-byte-drop rs ll meta) ;; drop byte
         (lets ((rs p (rand rs (sizeb (car ll)))))
            (values sed-byte-drop rs 
               (cons (edit-byte-vector (car ll) p (λ (old tl) tl)) (cdr ll))
               (inc meta 'byte-drop) 0)))
      
      (define (sed-byte-inc rs ll meta) ;; increment a byte value mod 256
         (lets ((rs p (rand rs (sizeb (car ll)))))
            (values sed-byte-inc rs 
               (cons (edit-byte-vector (car ll) p (λ (old tl) (cons (band 255 (+ old 1)) tl))) (cdr ll))
               (inc meta 'byte-inc) 0)))
      
      (define (sed-byte-dec rs ll meta) ;; increment a byte value mod 256
         (lets ((rs p (rand rs (sizeb (car ll)))))
            (values sed-byte-dec rs 
               (cons (edit-byte-vector (car ll) p (λ (old tl) (cons (if (= old 0) 255 (- old 1)) tl))) (cdr ll))
               (inc meta 'byte-dec) 0)))

      (define (sed-byte-flip rs ll meta) ;; flip a bit in a byte
         (lets 
            ((rs p (rand rs (sizeb (car ll))))
             (rs pos (rand rs 8))
             (b (<< 1 pos)))
            (values sed-byte-flip rs 
               (cons (edit-byte-vector (car ll) p (λ (old tl) (cons (bxor b old) tl))) (cdr ll))
               (inc meta 'byte-inc) 0)))

      (define (sed-byte-insert rs ll meta) ;; insert a byte
         (lets 
            ((rs p (rand rs (sizeb (car ll))))
             (rs b (rand rs 256)))
            (values sed-byte-insert rs 
               (cons (edit-byte-vector (car ll) p (λ (old tl) (ilist b old tl))) (cdr ll))
               (inc meta 'byte-insert) 0)))
    
      ;; rs → rs' n
      (define (repeat-len rs)
         (let loop ((rs rs) (limit #b10))
            (lets ((rs x (rand rs 2)))
               (cond
                  ((eq? x 0) (rand rs limit))
                  ((= limit #x20000) (rand rs limit)) ; max 128k
                  (else (loop rs (<< limit 1)))))))
      
      (define (push n x lst)
         (if (eq? n 0)
            lst
            (push (- n 1) x (cons x lst))))

      (define (sed-byte-repeat rs ll meta) ;; insert a byte
         (lets 
            ((rs p (rand rs (sizeb (car ll))))
             (rs n (repeat-len rs)))
            (values sed-byte-repeat rs 
               (cons (edit-byte-vector (car ll) p (λ (old tl) (push n old (cons old tl)))) (cdr ll))
               (inc meta 'byte-repeat) 0)))
      
      (define (sed-byte-random rs ll meta) ;; swap a byte
         (lets 
            ((rs p (rand rs (sizeb (car ll))))
             (rs b (rand rs 256)))
            (values sed-byte-random rs 
               (cons (edit-byte-vector (car ll) p (λ (old tl) (cons b tl))) (cdr ll))
               (inc meta 'byte-random) 0)))
      
      (define (sed-byte-perm rs ll meta) ;; permute a few bytes
         (lets ((rs p (rand rs (sizeb (car ll)))))
            (values sed-byte-perm rs 
               (cons 
                  (edit-byte-vector (car ll) p 
                     (λ (old tl)
                        (lets
                           ((lst (cons old tl))
                            (rs n (rand-range rs 2 20)) ;; fixme: magic constant, should use something like repeat-len
                            (head (take lst n))
                            (tail (drop lst n))
                            (rs head (random-permutation rs head)))
                           (append head tail))))
                  (cdr ll))
               (inc meta 'byte-perm) 0)))

      ;;;
      ;;; Guessed Parse-tree Mutations
      ;;;

      (define usual-delims ; <- could be settable from command line
         (list->ff
            '((40 . 41)    ; ()
              (91 . 93)    ; []
              (60 . 62)    ; <>
              (123 . 125)  ; {}
              (34 . 34)    ; ""
              (39 . 39)))) ; ''

      ;; → lst #false = ran out of data trying to parse up to close, but lst is the same with partial parsing
      ;; → lst tail-lst = did successfully parse up to close. ready node is lst, tail is following data
      (define (grow lst close rout)
         (if (null? lst)
            (values (reverse rout) #false) ;; out of data, didn't find close. return partial parse.
            (lets ((hd lst lst))
               (cond
                  ((eq? hd close)
                     ;; match complete, return with rest of list
                     (values (reverse (cons close rout)) lst))
                  ((get usual-delims hd #false) =>
                     (λ (next-close)
                        (lets ((this lst (grow lst next-close null)))
                           (if lst ;; we didn't run out of data and this is a single tree node
                              (grow lst close (cons (cons hd this) rout))
                              ;; we ran out of data. this is a list of partial parses (having the data of
                              ;; lst after hd in some form) which we want to preserve as tail
                              (values (append (reverse rout) (cons hd this)) #false)))))
                  (else ;; add one byte to this node
                     (grow lst close (cons hd rout)))))))

      ;; count how many list nodes are in a tree structure
      (define (count-nodes lst)
         (let loop ((lst lst) (n 0))
            (cond
               ((null? lst) n)
               ((pair? (car lst))
                  (loop (cdr lst)
                     (loop (car lst) (+ n 1))))
               (else
                  (loop (cdr lst) n)))))

      ;; lst → a list of lists (not counting tails) in lst, when walked recursively, not counting lst itself
      (define (sublists lst)
         (let loop ((lst lst) (found null))
            (if (null? lst)
               found
               (let ((hd (car lst)))
                  (if (pair? hd)
                     (loop (cdr lst)
                        (loop hd (cons hd found)))
                     (loop (cdr lst) found))))))

      (define (pick-sublist rs lst)
         (let ((subs (sublists lst)))
            (if (null? subs)
               (values rs #false)
               (lets ((rs n (rand rs (length subs))))
                  (values rs (lref subs n))))))

      ;; replace the node (sub . tail) with (op (sub . tail))
      (define (edit-sublist lst sub op)
         (if (pair? lst)
            (if (eq? (car lst) sub)
               (cons (op lst) (cdr lst))
               (cons (edit-sublist (car lst) sub op)
                     (edit-sublist (cdr lst) sub op)))
            lst))

      ;; lst (ff of node → (node → node)) → lst' ; <- could also be done with a recursive-mapn
      (define (edit-sublists lst opff)
         (if (pair? lst)
            (let ((hd (car lst)))
               (if (pair? hd)
                  (let ((maybe-op (get opff hd #false)))
                     (if maybe-op
                        (cons (maybe-op (car lst))
                           (edit-sublists (cdr lst) opff))
                        (cons (edit-sublists (car lst) opff)
                           (edit-sublists (cdr lst) opff))))
                  (cons (car lst)
                     (edit-sublists (cdr lst) opff))))
            lst))

      (define (partial-parse lst)
         (let loop ((lst lst) (rout null))
            (if (null? lst)
               (reverse rout)
               (lets ((closep (get usual-delims (car lst) #false)))
                  (if closep
                     (lets
                        ((hd (car lst))
                         (this lst (grow (cdr lst) closep null)))
                        (if lst
                           (loop lst (cons (cons hd this) rout))
                           (append (reverse rout) (cons hd this))))
                     (loop (cdr lst) (cons (car lst) rout)))))))

      (define (flatten node tl)
         (cond
            ((null? node) tl)
            ((pair? node) (flatten (car node) (flatten (cdr node) tl)))
            (else (cons node tl))))

     (define (sed-byte-inc rs ll meta) ;; increment a byte value mod 256
         (lets ((rs p (rand rs (sizeb (car ll)))))
            (values sed-byte-inc rs
               (cons (edit-byte-vector (car ll) p (λ (old tl) (cons (band 255 (+ old 1)) tl))) (cdr ll))
               (inc meta 'byte-inc) 0)))

      (define (sed-tree-op op name)
         (define (self rs ll meta)
            (let ((meta (inc meta name)))
               (lets
                  ((lst (partial-parse (vector->list (car ll))))
                   ;(_ (if (not (equal? (vector->list (car ll)) (flatten lst null))) (error "partial parse bug: " (list (car ll) 'parses 'to lst))))
                   (rs sub (pick-sublist rs lst)) ;; choose partially parsed node to mutate ;; fixme: not checked for F
                   (lst (edit-sublist lst sub op)))
                  (values self rs
                     (flush-bvecs (flatten lst null) (cdr ll))
                     meta 0))))
         self)

      ;; overwrite one node with one of the others
      (define (sed-tree-swap-one rs ll meta)
         (lets
            ((lst (partial-parse (vector->list (car ll)))) ;; (byte|node ...)
             (subs (sublists lst)))
            (if (length< subs 3)
               ;; drop priority, nothing cool here
               (values sed-tree-swap-one rs ll meta -1)
               (lets
                  ((rs toswap (reservoir-sample rs subs 2))
                   (a (car toswap))
                   (b (cadr toswap))
                   (rs delta (rand rs 2))
                   (lst (edit-sublist lst a (λ (node) (cons b (cdr node))))))
                  (values sed-tree-swap-one rs
                     (flush-bvecs (flatten lst null) (cdr ll))
                     (inc meta 'tree-swap-one)
                     delta)))))

      ;; pairwise swap of two nodes
      (define (sed-tree-swap-two rs ll meta)
         (lets
            ((lst (partial-parse (vector->list (car ll)))) ;; (byte|node ...)
             (subs (sublists lst)))
            (if (length< subs 3)
               ;; drop priority, nothing cool here
               (values sed-tree-swap-two rs ll meta -1)
               (lets
                  ((rs toswap (reservoir-sample rs subs 2))
                   (a (car toswap))
                   (b (cadr toswap))
                   (rs delta (rand rs 2))
                   (mapping (list->ff (list (cons a (λ (x) b)) (cons b (λ (x) a)))))
                   (lst (edit-sublists lst mapping)))
                  (values sed-tree-swap-one rs
                     (flush-bvecs (flatten lst null) (cdr ll))
                     (inc meta 'tree-swap-two)
                     delta)))))

      (define sed-tree-del (sed-tree-op (λ (node) null) 'tree-del))

      (define sed-tree-dup (sed-tree-op (λ (node) (cons (car node) node)) 'tree-dup))

      ; [i]nsert
      ; [r]epeat
      ; [d]rop
      ; [s]wap

      (define *mutations*
         (list

            ;;; stateless (apart from priorities)

            ;; byte-level 
            (tuple "bd" sed-byte-drop "drop a byte")
            (tuple "bf" sed-byte-flip "flip one bit")
            (tuple "bi" sed-byte-insert "insert a random byte")
            (tuple "br" sed-byte-repeat "repeat a byte")
            (tuple "bp" sed-byte-perm "permute some bytes")
            (tuple "bei" sed-byte-inc "increment a byte by one")
            (tuple "bed" sed-byte-dec "decrement a byte by one")
            (tuple "ber" sed-byte-dec "swap a byte with a random one")

            ;; special
            (tuple "num" sed-num "modify a textual number")

            ;; line-level

            ;; tree-level

            (tuple "td" sed-tree-del "delete a node")
            (tuple "tr2" sed-tree-dup "duplicate a node")
            (tuple "ts1" sed-tree-swap-one "swap one node with another one")
            (tuple "ts2" sed-tree-swap-two "swap two nodes pairwise")

            ;; utf-8

            ;; lexical?

            ;;; incrementals

            ))

      (define default-mutations
         "num=10,td=5,tr2=5,ts1=5,ts2=5,bd,bf,bi,br,bp,bei,bed,ber")

      (define (name->mutation str)
         (or (choose *mutations* str)
             (begin
               (print*-to (list "Unknown mutation: " str) stderr)
               #false)))

      ;; #f | (name . priority) → #f | (priority . func)
      (define (priority->fuzzer node)
         (cond
            ((not node) #false)
            ((name->mutation (car node)) => 
               (λ (func) (cons (cdr node) func)))
            (else #false)))

      ; limit to [2 ... 1000]
      (define (adjust-priority pri delta)
         (if (eq? delta 0)
            pri
            (max 1 (min 100 (+ pri delta)))))

      ;; rs pris → rs' pris'
      (define (weighted-permutation rs pris)
         (lets    
            ((rs ppris ; ((x . (pri . fn)) ...)
               (fold-map
                  (λ (rs node)
                     (lets ((rs pri (rand rs (car node))))
                        (values rs (cons pri node))))
                  rs pris)))
            (values rs (map cdr (sort car> ppris)))))

      ;; ((priority . mutafn) ...) → (rs ll meta → mutator' rs' ll' meta')
      (define (mux-fuzzers fs)
         (λ (rs ll meta)
            (let loop ((ll ll)) ;; <- force up to a data node
               (cond
                  ((pair? ll)
                     (lets ((rs pfs (weighted-permutation rs fs))) ;; ((priority . mutafn) ...)
                        (let loop ((pfs pfs) (out null) (rs rs)) ;; try each in order
                           (if (null? pfs) ;; no mutation worked
                              (values (mux-fuzzers out) rs ll meta)
                              (lets
                                 ((mfn rs mll mmeta delta 
                                    ((cdar pfs) rs ll meta))
                                  (out ;; always remember whatever was learned
                                    (cons (cons (adjust-priority (caar pfs) delta) mfn) out)))
                                 (if (equal? (car ll) (car mll)) 
                                    ;; try something else if no changes, but update state
                                    (loop (cdr pfs) out rs)
                                    (values (mux-fuzzers (append out (cdr pfs))) rs mll mmeta)))))))
                  ((null? ll)
                     (values (mux-fuzzers fs) rs ll meta))
                  (else 
                     (loop (ll)))))))

      ;; str → mutator | #f
      (define (string->mutator str)
         (lets
            ((ps (map c/=/ (c/,/ str))) ; ((name [priority-str]) ..)
             (ps (map selection->priority ps))
             (ps (map (λ (x) (if x (cons (car x) (* (cdr x) 10)) x)) ps)) ; scale priorities to 10x
             (fs (map priority->fuzzer ps)))
            (if (all self fs) 
               (mux-fuzzers (sort car> fs))
               #false)))

))