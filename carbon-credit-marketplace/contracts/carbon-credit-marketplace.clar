;; Carbon Credit Marketplace Smart Contract
;; A simplified platform for minting, trading, and retiring carbon offset credits as NFTs

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-INVALID-AMOUNT (err u102))
(define-constant ERR-ALREADY-RETIRED (err u103))
(define-constant ERR-NOT-OWNER (err u104))

;; Data Variables
(define-data-var last-token-id uint u0)
(define-data-var platform-fee-rate uint u250) ;; 2.5% in basis points
(define-data-var total-credits-minted uint u0)
(define-data-var total-credits-retired uint u0)

;; NFT Definition
(define-non-fungible-token carbon-credit uint)

;; Carbon Credit Data Structure
(define-map carbon-credits uint {
    project-name: (string-utf8 100),
    issuer: principal,
    co2-amount: uint, ;; tonnes of CO2 equivalent
    vintage: uint, ;; year of generation
    standard: (string-ascii 50), ;; e.g., "VCS", "CDM", "Gold Standard"
    metadata-uri: (string-utf8 256),
    retired: bool,
    retirement-date: (optional uint),
    created-at: uint
})

;; Marketplace Listings
(define-map credit-listings uint {
    seller: principal,
    price: uint,
    listed-at: uint
})

;; User Statistics
(define-map user-stats principal {
    credits-purchased: uint,
    credits-retired: uint,
    co2-offset: uint
})

;; SIP-009 Implementation
(define-read-only (get-last-token-id)
    (ok (var-get last-token-id))
)

(define-read-only (get-token-uri (token-id uint))
    (match (map-get? carbon-credits token-id)
        credit (ok (some (get metadata-uri credit)))
        (ok none)
    )
)

(define-read-only (get-owner (token-id uint))
    (ok (nft-get-owner? carbon-credit token-id))
)

(define-public (transfer (token-id uint) (sender principal) (recipient principal))
    (begin
        (asserts! (is-eq tx-sender sender) ERR-NOT-AUTHORIZED)
        (asserts! (is-some (nft-get-owner? carbon-credit token-id)) ERR-NOT-FOUND)
        (nft-transfer? carbon-credit token-id sender recipient)
    )
)

;; Carbon Credit Minting
(define-public (mint-carbon-credit 
    (project-name (string-utf8 100))
    (co2-amount uint)
    (vintage uint)
    (standard (string-ascii 50))
    (metadata-uri (string-utf8 256))
    (recipient principal))
    
    (let ((token-id (+ (var-get last-token-id) u1)))
        ;; Validate inputs
        (asserts! (> co2-amount u0) ERR-INVALID-AMOUNT)
        (asserts! (> vintage u1990) ERR-INVALID-AMOUNT)
        
        ;; Mint the NFT
        (try! (nft-mint? carbon-credit token-id recipient))
        
        ;; Store credit data
        (map-set carbon-credits token-id {
            project-name: project-name,
            issuer: tx-sender,
            co2-amount: co2-amount,
            vintage: vintage,
            standard: standard,
            metadata-uri: metadata-uri,
            retired: false,
            retirement-date: none,
            created-at: block-height
        })
        
        ;; Update counters
        (var-set last-token-id token-id)
        (var-set total-credits-minted (+ (var-get total-credits-minted) u1))
        
        (ok token-id)
    )
)

;; Marketplace Functions
(define-public (list-credit-for-sale (token-id uint) (price uint))
    (let ((credit (unwrap! (map-get? carbon-credits token-id) ERR-NOT-FOUND)))
        ;; Verify ownership and conditions
        (asserts! (is-eq tx-sender (unwrap! (nft-get-owner? carbon-credit token-id) ERR-NOT-FOUND)) ERR-NOT-OWNER)
        (asserts! (not (get retired credit)) ERR-ALREADY-RETIRED)
        (asserts! (> price u0) ERR-INVALID-AMOUNT)
        
        ;; Create listing
        (map-set credit-listings token-id {
            seller: tx-sender,
            price: price,
            listed-at: block-height
        })
        
        (ok true)
    )
)

(define-public (remove-listing (token-id uint))
    (let ((listing (unwrap! (map-get? credit-listings token-id) ERR-NOT-FOUND)))
        ;; Only seller can remove listing
        (asserts! (is-eq tx-sender (get seller listing)) ERR-NOT-AUTHORIZED)
        
        ;; Remove listing
        (map-delete credit-listings token-id)
        (ok true)
    )
)

(define-public (purchase-credit (token-id uint))
    (let ((listing (unwrap! (map-get? credit-listings token-id) ERR-NOT-FOUND))
          (credit (unwrap! (map-get? carbon-credits token-id) ERR-NOT-FOUND))
          (seller (get seller listing))
          (price (get price listing))
          (platform-fee (/ (* price (var-get platform-fee-rate)) u10000))
          (seller-amount (- price platform-fee)))
        
        ;; Verify buyer is not seller
        (asserts! (not (is-eq tx-sender seller)) ERR-NOT-AUTHORIZED)
        (asserts! (not (get retired credit)) ERR-ALREADY-RETIRED)
        
        ;; Transfer STX payment
        (try! (stx-transfer? seller-amount tx-sender seller))
        (try! (stx-transfer? platform-fee tx-sender CONTRACT-OWNER))
        
        ;; Transfer NFT
        (try! (nft-transfer? carbon-credit token-id seller tx-sender))
        
        ;; Remove listing
        (map-delete credit-listings token-id)
        
        ;; Update buyer stats
        (update-user-stats tx-sender (get co2-amount credit) u0)
        
        (ok true)
    )
)

;; Credit Retirement
(define-public (retire-carbon-credit (token-id uint))
    (let ((credit (unwrap! (map-get? carbon-credits token-id) ERR-NOT-FOUND)))
        ;; Verify ownership and retirement status
        (asserts! (is-eq tx-sender (unwrap! (nft-get-owner? carbon-credit token-id) ERR-NOT-FOUND)) ERR-NOT-OWNER)
        (asserts! (not (get retired credit)) ERR-ALREADY-RETIRED)
        
        ;; Mark as retired
        (map-set carbon-credits token-id 
            (merge credit {
                retired: true,
                retirement-date: (some block-height)
            })
        )
        
        ;; Remove from marketplace if listed
        (map-delete credit-listings token-id)
        
        ;; Update global and user statistics
        (var-set total-credits-retired (+ (var-get total-credits-retired) u1))
        (update-user-stats tx-sender u0 (get co2-amount credit))
        
        (ok true)
    )
)

;; Helper function for updating user statistics
(define-private (update-user-stats (user principal) (purchased uint) (retired uint))
    (let ((current-stats (default-to 
            { credits-purchased: u0, credits-retired: u0, co2-offset: u0 } 
            (map-get? user-stats user))))
        
        (map-set user-stats user {
            credits-purchased: (+ (get credits-purchased current-stats) purchased),
            credits-retired: (+ (get credits-retired current-stats) u1),
            co2-offset: (+ (get co2-offset current-stats) retired)
        })
    )
)

;; Read-only functions for data retrieval
(define-read-only (get-credit-info (token-id uint))
    (map-get? carbon-credits token-id)
)

(define-read-only (get-listing-info (token-id uint))
    (map-get? credit-listings token-id)
)

(define-read-only (get-user-stats (user principal))
    (map-get? user-stats user)
)

(define-read-only (get-platform-stats)
    {
        total-minted: (var-get total-credits-minted),
        total-retired: (var-get total-credits-retired),
        platform-fee-rate: (var-get platform-fee-rate)
    }
)

;; Admin functions
(define-public (set-platform-fee-rate (new-rate uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (asserts! (<= new-rate u1000) ERR-INVALID-AMOUNT) ;; Max 10%
        (var-set platform-fee-rate new-rate)
        (ok true)
    )
)