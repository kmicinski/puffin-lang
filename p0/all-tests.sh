racket test.rkt -m parse-stackprog -g goldens/parse-pop-behavior.gld stackprogs/pop-behavior.sp
racket test.rkt -m interp-stackprog -g goldens/interp-pop-behavior-1.gld -i input-streams/1.in stackprogs/pop-behavior.sp
racket test.rkt -m interp-stackprog -g goldens/interp-pop-behavior-2.gld -i input-streams/2.in stackprogs/pop-behavior.sp
racket test.rkt -m interp-stackprog -g goldens/interp-pop-behavior-3.gld -i input-streams/3.in stackprogs/pop-behavior.sp
racket test.rkt -m interp-stackprog -g goldens/interp-pop-behavior-4.gld -i input-streams/4.in stackprogs/pop-behavior.sp
racket test.rkt -m parse-stackprog -g goldens/parse-read-plus-constant.gld stackprogs/read-plus-constant.sp
racket test.rkt -m interp-stackprog -g goldens/interp-read-plus-constant-1.gld -i input-streams/1.in stackprogs/read-plus-constant.sp
racket test.rkt -m interp-stackprog -g goldens/interp-read-plus-constant-2.gld -i input-streams/2.in stackprogs/read-plus-constant.sp
racket test.rkt -m interp-stackprog -g goldens/interp-read-plus-constant-3.gld -i input-streams/3.in stackprogs/read-plus-constant.sp
racket test.rkt -m interp-stackprog -g goldens/interp-read-plus-constant-4.gld -i input-streams/4.in stackprogs/read-plus-constant.sp
racket test.rkt -m parse-stackprog -g goldens/parse-sub-order-and-neg.gld stackprogs/sub-order-and-neg.sp
racket test.rkt -m interp-stackprog -g goldens/interp-sub-order-and-neg-1.gld -i input-streams/1.in stackprogs/sub-order-and-neg.sp
racket test.rkt -m interp-stackprog -g goldens/interp-sub-order-and-neg-2.gld -i input-streams/2.in stackprogs/sub-order-and-neg.sp
racket test.rkt -m interp-stackprog -g goldens/interp-sub-order-and-neg-3.gld -i input-streams/3.in stackprogs/sub-order-and-neg.sp
racket test.rkt -m interp-stackprog -g goldens/interp-sub-order-and-neg-4.gld -i input-streams/4.in stackprogs/sub-order-and-neg.sp
racket test.rkt -m parse-stackprog -g goldens/parse-sum-then-mul.gld stackprogs/sum-then-mul.sp
racket test.rkt -m interp-stackprog -g goldens/interp-sum-then-mul-1.gld -i input-streams/1.in stackprogs/sum-then-mul.sp
racket test.rkt -m interp-stackprog -g goldens/interp-sum-then-mul-2.gld -i input-streams/2.in stackprogs/sum-then-mul.sp
racket test.rkt -m interp-stackprog -g goldens/interp-sum-then-mul-3.gld -i input-streams/3.in stackprogs/sum-then-mul.sp
racket test.rkt -m interp-stackprog -g goldens/interp-sum-then-mul-4.gld -i input-streams/4.in stackprogs/sum-then-mul.sp
racket test.rkt -m translate-infix -g goldens/infix-interp-1-1.gld -i input-streams/1.in infix-programs/1.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-1-2.gld -i input-streams/2.in infix-programs/1.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-1-3.gld -i input-streams/3.in infix-programs/1.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-1-4.gld -i input-streams/4.in infix-programs/1.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-2-1.gld -i input-streams/1.in infix-programs/2.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-2-2.gld -i input-streams/2.in infix-programs/2.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-2-3.gld -i input-streams/3.in infix-programs/2.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-2-4.gld -i input-streams/4.in infix-programs/2.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-3-1.gld -i input-streams/1.in infix-programs/3.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-3-2.gld -i input-streams/2.in infix-programs/3.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-3-3.gld -i input-streams/3.in infix-programs/3.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-3-4.gld -i input-streams/4.in infix-programs/3.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-4-1.gld -i input-streams/1.in infix-programs/4.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-4-2.gld -i input-streams/2.in infix-programs/4.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-4-3.gld -i input-streams/3.in infix-programs/4.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-4-4.gld -i input-streams/4.in infix-programs/4.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-5-1.gld -i input-streams/1.in infix-programs/5.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-5-2.gld -i input-streams/2.in infix-programs/5.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-5-3.gld -i input-streams/3.in infix-programs/5.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-5-4.gld -i input-streams/4.in infix-programs/5.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-6-1.gld -i input-streams/1.in infix-programs/6.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-6-2.gld -i input-streams/2.in infix-programs/6.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-6-3.gld -i input-streams/3.in infix-programs/6.infix
racket test.rkt -m translate-infix -g goldens/infix-interp-6-4.gld -i input-streams/4.in infix-programs/6.infix
