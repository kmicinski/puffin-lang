(program (let ([x 2]) (let ([x x]) (let ([x x]) x))))

;; you can't ... 
movq -8(%rbp), -16(%rbp) ;; NOT ALLOWED
movq -8(%rbp), %rcx
movq %rcx    , -16(%rbp)