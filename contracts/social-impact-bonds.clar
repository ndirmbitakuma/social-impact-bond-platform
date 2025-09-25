;; Social Impact Bonds Smart Contract
;; Fund social programs, measure outcomes, and distribute returns based on success metrics

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-insufficient-funds (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-invalid-amount (err u104))
(define-constant err-program-not-active (err u105))
(define-constant err-program-not-funded (err u106))
(define-constant err-already-reported (err u107))
(define-constant err-validation-period-ended (err u108))
(define-constant err-program-not-completed (err u109))
(define-constant err-already-claimed (err u110))
(define-constant err-invalid-rating (err u111))

;; Program states
(define-constant program-proposed u1)
(define-constant program-approved u2)
(define-constant program-funded u3)
(define-constant program-active u4)
(define-constant program-completed u5)
(define-constant program-validated u6)

;; Validation and funding parameters
(define-constant minimum-funding u100000) ;; 0.1 STX minimum
(define-constant validation-period u1008) ;; ~1 week in blocks
(define-constant max-programs u1000)
(define-constant max-investors-per-program u100)

;; Performance thresholds for returns
(define-constant exceptional-threshold u90) ;; 90%+ success
(define-constant target-threshold u75) ;; 75%+ success  
(define-constant minimum-threshold u50) ;; 50%+ success

;; Return multipliers (basis points: 10000 = 100%)
(define-constant exceptional-return u12000) ;; 120% return
(define-constant target-return u11000) ;; 110% return
(define-constant minimum-return u10500) ;; 105% return
(define-constant poor-return u9500) ;; 95% return

;; Data Variables
(define-data-var program-counter uint u0)
(define-data-var total-platform-funding uint u0)
(define-data-var total-programs-created uint u0)
(define-data-var total-successful-programs uint u0)
(define-data-var platform-active bool true)

;; Data Maps

;; Program information
(define-map programs uint {
    creator: principal,
    name: (string-ascii 256),
    description: (string-ascii 512),
    target-funding: uint,
    current-funding: uint,
    outcome-description: (string-ascii 512),
    creation-block: uint,
    funding-deadline: uint,
    execution-deadline: uint,
    state: uint,
    success-rate: uint,
    validator-count: uint,
    total-validation-score: uint,
    funds-withdrawn: bool,
    returns-distributed: bool
})

;; Investment tracking
(define-map investments {program-id: uint, investor: principal} {
    amount: uint,
    investment-block: uint,
    returns-claimed: bool
})

;; Program investors list
(define-map program-investors uint (list 100 principal))

;; Validator tracking
(define-map validators {program-id: uint, validator: principal} {
    rating: uint,
    validation-block: uint,
    is-verified: bool
})

;; Platform statistics
(define-map user-stats principal {
    programs-created: uint,
    total-invested: uint,
    total-returns: uint,
    validations-completed: uint,
    reputation-score: uint
})

;; Helper Functions

;; Check if program exists
(define-private (program-exists (program-id uint))
    (is-some (map-get? programs program-id))
)

;; Check if user has invested in program
(define-private (has-investment (program-id uint) (investor principal))
    (is-some (map-get? investments {program-id: program-id, investor: investor}))
)

;; Calculate return multiplier based on success rate
(define-private (calculate-return-multiplier (success-rate uint))
    (if (>= success-rate exceptional-threshold)
        exceptional-return
        (if (>= success-rate target-threshold)
            target-return
            (if (>= success-rate minimum-threshold)
                minimum-return
                poor-return
            )
        )
    )
)

;; Calculate user investment return
(define-private (calculate-user-return (program-id uint) (investor principal))
    (match (map-get? investments {program-id: program-id, investor: investor})
        investment-data
            (match (map-get? programs program-id)
                program-data
                    (let 
                        ((success-rate (get success-rate program-data))
                         (multiplier (calculate-return-multiplier success-rate))
                         (invested-amount (get amount investment-data)))
                        (/ (* invested-amount multiplier) u10000)
                    )
                u0
            )
        u0
    )
)

;; Check if program is in validation period
(define-private (in-validation-period (program-id uint))
    (match (map-get? programs program-id)
        program-data
            (and 
                (is-eq (get state program-data) program-completed)
                (<= stacks-block-height (+ (get execution-deadline program-data) validation-period))
            )
        false
    )
)

;; Public Functions

;; Create a new social impact program
(define-public (create-program (name (string-ascii 256)) (description (string-ascii 512)) (target-funding uint) (outcome-description (string-ascii 512)) (execution-duration uint))
    (let 
        ((new-program-id (+ (var-get program-counter) u1))
         (current-block stacks-block-height))
        
        (asserts! (> target-funding minimum-funding) err-invalid-amount)
        (asserts! (> execution-duration u0) err-invalid-amount)
        (asserts! (<= new-program-id max-programs) err-not-found)
        
        ;; Create new program
        (map-set programs new-program-id {
            creator: tx-sender,
            name: name,
            description: description,
            target-funding: target-funding,
            current-funding: u0,
            outcome-description: outcome-description,
            creation-block: current-block,
            funding-deadline: (+ current-block u1008), ;; 1 week to fund
            execution-deadline: (+ current-block execution-duration),
            state: program-proposed,
            success-rate: u0,
            validator-count: u0,
            total-validation-score: u0,
            funds-withdrawn: false,
            returns-distributed: false
        })
        
        ;; Initialize empty investors list
        (map-set program-investors new-program-id (list))
        
        ;; Update user stats
        (let 
            ((current-stats (default-to {programs-created: u0, total-invested: u0, total-returns: u0, validations-completed: u0, reputation-score: u0} 
                                      (map-get? user-stats tx-sender))))
            (map-set user-stats tx-sender 
                (merge current-stats {
                    programs-created: (+ (get programs-created current-stats) u1),
                    reputation-score: (+ (get reputation-score current-stats) u5)
                })
            )
        )
        
        ;; Update platform stats
        (var-set program-counter new-program-id)
        (var-set total-programs-created (+ (var-get total-programs-created) u1))
        
        (ok new-program-id)
    )
)

;; Approve a program (simplified - in practice would require governance)
(define-public (approve-program (program-id uint))
    (let 
        ((program-data (unwrap! (map-get? programs program-id) err-not-found)))
        
        (asserts! (is-eq tx-sender contract-owner) err-owner-only) ;; Simplified approval
        (asserts! (is-eq (get state program-data) program-proposed) err-program-not-active)
        
        (map-set programs program-id 
            (merge program-data {state: program-approved})
        )
        
        (ok true)
    )
)

;; Invest in an approved program
(define-public (invest-in-program (program-id uint) (amount uint))
    (let 
        ((program-data (unwrap! (map-get? programs program-id) err-not-found))
         (current-investors (default-to (list) (map-get? program-investors program-id)))
         (has-existing-investment (has-investment program-id tx-sender)))
        
        (asserts! (> amount u0) err-invalid-amount)
        (asserts! (is-eq (get state program-data) program-approved) err-program-not-active)
        (asserts! (<= stacks-block-height (get funding-deadline program-data)) err-program-not-active)
        (asserts! (< (len current-investors) max-investors-per-program) err-insufficient-funds)
        
        ;; Transfer funds to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Update or create investment record
        (if has-existing-investment
            (let 
                ((existing-investment (unwrap-panic (map-get? investments {program-id: program-id, investor: tx-sender}))))
                (map-set investments {program-id: program-id, investor: tx-sender}
                    (merge existing-investment {
                        amount: (+ (get amount existing-investment) amount)
                    })
                )
            )
            (begin
                (map-set investments {program-id: program-id, investor: tx-sender} {
                    amount: amount,
                    investment-block: stacks-block-height,
                    returns-claimed: false
                })
                ;; Add to investors list
                (map-set program-investors program-id 
                    (match (as-max-len? (append current-investors tx-sender) u100)
                        new-list new-list
                        current-investors
                    )
                )
            )
        )
        
        ;; Update program funding
        (let 
            ((new-funding (+ (get current-funding program-data) amount))
             (new-state (if (>= new-funding (get target-funding program-data)) program-funded program-approved)))
            
            (map-set programs program-id 
                (merge program-data {
                    current-funding: new-funding,
                    state: new-state
                })
            )
        )
        
        ;; Update user stats
        (let 
            ((current-stats (default-to {programs-created: u0, total-invested: u0, total-returns: u0, validations-completed: u0, reputation-score: u0} 
                                      (map-get? user-stats tx-sender))))
            (map-set user-stats tx-sender 
                (merge current-stats {
                    total-invested: (+ (get total-invested current-stats) amount),
                    reputation-score: (+ (get reputation-score current-stats) u2)
                })
            )
        )
        
        ;; Update platform funding
        (var-set total-platform-funding (+ (var-get total-platform-funding) amount))
        
        (ok true)
    )
)

;; Service provider withdraws funds to execute program
(define-public (withdraw-program-funds (program-id uint))
    (let 
        ((program-data (unwrap! (map-get? programs program-id) err-not-found)))
        
        (asserts! (is-eq tx-sender (get creator program-data)) err-unauthorized)
        (asserts! (is-eq (get state program-data) program-funded) err-program-not-funded)
        (asserts! (not (get funds-withdrawn program-data)) err-already-claimed)
        
        ;; Transfer funds to program creator
        (try! (as-contract (stx-transfer? (get current-funding program-data) tx-sender (get creator program-data))))
        
        ;; Update program state
        (map-set programs program-id 
            (merge program-data {
                state: program-active,
                funds-withdrawn: true
            })
        )
        
        (ok true)
    )
)

;; Report program outcomes (by creator)
(define-public (report-outcome (program-id uint) (success-rate uint))
    (let 
        ((program-data (unwrap! (map-get? programs program-id) err-not-found)))
        
        (asserts! (is-eq tx-sender (get creator program-data)) err-unauthorized)
        (asserts! (is-eq (get state program-data) program-active) err-program-not-active)
        (asserts! (> stacks-block-height (get execution-deadline program-data)) err-program-not-completed)
        (asserts! (<= success-rate u100) err-invalid-rating)
        
        ;; Update program with reported outcome
        (map-set programs program-id 
            (merge program-data {
                state: program-completed,
                success-rate: success-rate
            })
        )
        
        (ok true)
    )
)

;; Validate program outcome (by independent validators)
(define-public (validate-outcome (program-id uint) (rating uint))
    (let 
        ((program-data (unwrap! (map-get? programs program-id) err-not-found))
         (has-validated (is-some (map-get? validators {program-id: program-id, validator: tx-sender}))))
        
        (asserts! (not has-validated) err-already-reported)
        (asserts! (<= rating u100) err-invalid-rating)
        (asserts! (in-validation-period program-id) err-validation-period-ended)
        
        ;; Record validation
        (map-set validators {program-id: program-id, validator: tx-sender} {
            rating: rating,
            validation-block: stacks-block-height,
            is-verified: true
        })
        
        ;; Update program validation stats
        (map-set programs program-id 
            (merge program-data {
                validator-count: (+ (get validator-count program-data) u1),
                total-validation-score: (+ (get total-validation-score program-data) rating)
            })
        )
        
        ;; Update validator stats
        (let 
            ((current-stats (default-to {programs-created: u0, total-invested: u0, total-returns: u0, validations-completed: u0, reputation-score: u0} 
                                      (map-get? user-stats tx-sender))))
            (map-set user-stats tx-sender 
                (merge current-stats {
                    validations-completed: (+ (get validations-completed current-stats) u1),
                    reputation-score: (+ (get reputation-score current-stats) u3)
                })
            )
        )
        
        (ok true)
    )
)

;; Finalize program and prepare for return distribution
(define-public (finalize-program (program-id uint))
    (let 
        ((program-data (unwrap! (map-get? programs program-id) err-not-found)))
        
        (asserts! (is-eq (get state program-data) program-completed) err-program-not-completed)
        (asserts! (> stacks-block-height (+ (get execution-deadline program-data) validation-period)) err-validation-period-ended)
        
        ;; Calculate final success rate (average of self-report and validations)
        (let 
            ((validator-count (get validator-count program-data))
             (final-success-rate 
                (if (> validator-count u0)
                    (/ (+ (get success-rate program-data) (/ (get total-validation-score program-data) validator-count)) u2)
                    (get success-rate program-data)
                )
             ))
            
            ;; Update program state
            (map-set programs program-id 
                (merge program-data {
                    state: program-validated,
                    success-rate: final-success-rate
                })
            )
            
            ;; Update platform success stats
            (begin
                (if (>= final-success-rate minimum-threshold)
                    (var-set total-successful-programs (+ (var-get total-successful-programs) u1))
                    true
                )
                u0
            )
            
            (ok final-success-rate)
        )
    )
)

;; Investors claim returns based on program performance
(define-public (claim-returns (program-id uint))
    (let 
        ((program-data (unwrap! (map-get? programs program-id) err-not-found))
         (investment-data (unwrap! (map-get? investments {program-id: program-id, investor: tx-sender}) err-not-found)))
        
        (asserts! (is-eq (get state program-data) program-validated) err-program-not-completed)
        (asserts! (not (get returns-claimed investment-data)) err-already-claimed)
        
        ;; Calculate return amount
        (let 
            ((return-amount (calculate-user-return program-id tx-sender)))
            
            ;; Transfer returns to investor
            (try! (as-contract (stx-transfer? return-amount tx-sender tx-sender)))
            
            ;; Update investment record
            (map-set investments {program-id: program-id, investor: tx-sender}
                (merge investment-data {returns-claimed: true})
            )
            
            ;; Update user stats
            (let 
                ((current-stats (default-to {programs-created: u0, total-invested: u0, total-returns: u0, validations-completed: u0, reputation-score: u0} 
                                          (map-get? user-stats tx-sender))))
                (map-set user-stats tx-sender 
                    (merge current-stats {
                        total-returns: (+ (get total-returns current-stats) return-amount),
                        reputation-score: (+ (get reputation-score current-stats) u1)
                    })
                )
            )
            
            (ok return-amount)
        )
    )
)

;; Read-Only Functions

;; Get program details
(define-read-only (get-program-details (program-id uint))
    (map-get? programs program-id)
)

;; Get investor position in a program
(define-read-only (get-investor-position (program-id uint) (investor principal))
    (map-get? investments {program-id: program-id, investor: investor})
)

;; Get program performance metrics
(define-read-only (get-program-performance (program-id uint))
    (match (map-get? programs program-id)
        program-data (ok {
            success-rate: (get success-rate program-data),
            validator-count: (get validator-count program-data),
            state: (get state program-data),
            funding-ratio: (/ (* (get current-funding program-data) u100) (get target-funding program-data))
        })
        err-not-found
    )
)

;; Get total platform funding
(define-read-only (get-total-funding)
    (var-get total-platform-funding)
)

;; Get platform success statistics
(define-read-only (get-success-statistics)
    {
        total-programs: (var-get total-programs-created),
        successful-programs: (var-get total-successful-programs),
        total-funding: (var-get total-platform-funding),
        success-rate: (if (> (var-get total-programs-created) u0)
            (/ (* (var-get total-successful-programs) u100) (var-get total-programs-created))
            u0
        )
    }
)

;; Get user statistics
(define-read-only (get-user-stats (user principal))
    (map-get? user-stats user)
)

;; Get program investors list
(define-read-only (get-program-investors (program-id uint))
    (map-get? program-investors program-id)
)

;; Calculate expected return for an investment
(define-read-only (get-expected-return (program-id uint) (investor principal))
    (match (map-get? programs program-id)
        program-data
            (if (is-eq (get state program-data) program-validated)
                (ok (calculate-user-return program-id investor))
                (ok u0) ;; Returns not yet determined
            )
        err-not-found
    )
)

;; Check if platform is active
(define-read-only (is-platform-active)
    (var-get platform-active)
)
