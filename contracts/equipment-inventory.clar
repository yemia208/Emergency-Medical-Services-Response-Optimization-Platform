;; Medical Equipment Inventory Management Contract
;; Ensures ambulances are properly stocked with life-saving equipment

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-EQUIPMENT-NOT-FOUND (err u301))
(define-constant ERR-INSUFFICIENT-STOCK (err u302))
(define-constant ERR-INVALID-QUANTITY (err u303))
(define-constant ERR-AMBULANCE-NOT-FOUND (err u304))
(define-constant ERR-EXPIRED-EQUIPMENT (err u305))

;; Data Variables
(define-data-var next-equipment-id uint u1)
(define-data-var next-ambulance-id uint u1)

;; Data Maps
(define-map equipment-types
  { equipment-id: uint }
  {
    name: (string-ascii 50),
    category: (string-ascii 30),
    unit: (string-ascii 20),
    min-stock-level: uint,
    max-stock-level: uint,
    shelf-life-days: uint,
    critical: bool
  }
)

(define-map ambulance-inventory
  { ambulance-id: uint, equipment-id: uint }
  {
    current-stock: uint,
    last-restocked: uint,
    expiration-date: uint,
    condition: (string-ascii 20),
    last-checked: uint
  }
)

(define-map central-inventory
  { equipment-id: uint }
  {
    total-stock: uint,
    reserved-stock: uint,
    available-stock: uint,
    reorder-point: uint,
    last-updated: uint
  }
)

(define-map maintenance-schedules
  { ambulance-id: uint, equipment-id: uint }
  {
    last-maintenance: uint,
    next-maintenance: uint,
    maintenance-interval: uint,
    maintenance-type: (string-ascii 30)
  }
)

(define-map authorized-inventory-managers principal bool)

;; Authorization Functions
(define-public (add-inventory-manager (manager principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-inventory-managers manager true))
  )
)

(define-private (is-inventory-manager (manager principal))
  (default-to false (map-get? authorized-inventory-managers manager))
)

;; Equipment Type Management
(define-public (register-equipment-type
  (name (string-ascii 50))
  (category (string-ascii 30))
  (unit (string-ascii 20))
  (min-stock uint)
  (max-stock uint)
  (shelf-life-days uint)
  (critical bool)
)
  (let ((equipment-id (var-get next-equipment-id)))
    (asserts! (is-inventory-manager tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (> max-stock min-stock) ERR-INVALID-QUANTITY)
    (asserts! (> shelf-life-days u0) ERR-INVALID-QUANTITY)
    (map-set equipment-types
      { equipment-id: equipment-id }
      {
        name: name,
        category: category,
        unit: unit,
        min-stock-level: min-stock,
        max-stock-level: max-stock,
        shelf-life-days: shelf-life-days,
        critical: critical
      }
    )
    (map-set central-inventory
      { equipment-id: equipment-id }
      {
        total-stock: u0,
        reserved-stock: u0,
        available-stock: u0,
        reorder-point: min-stock,
        last-updated: block-height
      }
    )
    (var-set next-equipment-id (+ equipment-id u1))
    (ok equipment-id)
  )
)

;; Inventory Management Functions
(define-public (update-central-stock (equipment-id uint) (quantity uint))
  (let ((inventory (unwrap! (map-get? central-inventory { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND)))
    (asserts! (is-inventory-manager tx-sender) ERR-NOT-AUTHORIZED)
    (map-set central-inventory
      { equipment-id: equipment-id }
      (merge inventory {
        total-stock: (+ (get total-stock inventory) quantity),
        available-stock: (+ (get available-stock inventory) quantity),
        last-updated: block-height
      })
    )
    (ok true)
  )
)

(define-public (stock-ambulance (ambulance-id uint) (equipment-id uint) (quantity uint))
  (let (
    (equipment (unwrap! (map-get? equipment-types { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND))
    (central-stock (unwrap! (map-get? central-inventory { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND))
    (expiration-date (+ block-height (get shelf-life-days equipment)))
  )
    (asserts! (is-inventory-manager tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (>= (get available-stock central-stock) quantity) ERR-INSUFFICIENT-STOCK)
    (asserts! (> quantity u0) ERR-INVALID-QUANTITY)

    ;; Update central inventory
    (map-set central-inventory
      { equipment-id: equipment-id }
      (merge central-stock {
        available-stock: (- (get available-stock central-stock) quantity),
        reserved-stock: (+ (get reserved-stock central-stock) quantity),
        last-updated: block-height
      })
    )

    ;; Update ambulance inventory
    (map-set ambulance-inventory
      { ambulance-id: ambulance-id, equipment-id: equipment-id }
      {
        current-stock: quantity,
        last-restocked: block-height,
        expiration-date: expiration-date,
        condition: "good",
        last-checked: block-height
      }
    )
    (ok true)
  )
)

(define-public (use-equipment (ambulance-id uint) (equipment-id uint) (quantity uint))
  (let ((inventory (unwrap! (map-get? ambulance-inventory { ambulance-id: ambulance-id, equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND)))
    (asserts! (is-inventory-manager tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (>= (get current-stock inventory) quantity) ERR-INSUFFICIENT-STOCK)
    (asserts! (> quantity u0) ERR-INVALID-QUANTITY)
    (map-set ambulance-inventory
      { ambulance-id: ambulance-id, equipment-id: equipment-id }
      (merge inventory {
        current-stock: (- (get current-stock inventory) quantity),
        last-checked: block-height
      })
    )
    (ok true)
  )
)

(define-public (schedule-maintenance (ambulance-id uint) (equipment-id uint) (interval uint))
  (let ((next-maintenance (+ block-height interval)))
    (asserts! (is-inventory-manager tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (> interval u0) ERR-INVALID-QUANTITY)
    (map-set maintenance-schedules
      { ambulance-id: ambulance-id, equipment-id: equipment-id }
      {
        last-maintenance: block-height,
        next-maintenance: next-maintenance,
        maintenance-interval: interval,
        maintenance-type: "routine"
      }
    )
    (ok true)
  )
)

(define-public (complete-maintenance (ambulance-id uint) (equipment-id uint))
  (let (
    (schedule (unwrap! (map-get? maintenance-schedules { ambulance-id: ambulance-id, equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND))
    (inventory (unwrap! (map-get? ambulance-inventory { ambulance-id: ambulance-id, equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND))
  )
    (asserts! (is-inventory-manager tx-sender) ERR-NOT-AUTHORIZED)
    (map-set maintenance-schedules
      { ambulance-id: ambulance-id, equipment-id: equipment-id }
      (merge schedule {
        last-maintenance: block-height,
        next-maintenance: (+ block-height (get maintenance-interval schedule))
      })
    )
    (map-set ambulance-inventory
      { ambulance-id: ambulance-id, equipment-id: equipment-id }
      (merge inventory {
        condition: "excellent",
        last-checked: block-height
      })
    )
    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-equipment-type (equipment-id uint))
  (map-get? equipment-types { equipment-id: equipment-id })
)

(define-read-only (get-ambulance-inventory (ambulance-id uint) (equipment-id uint))
  (map-get? ambulance-inventory { ambulance-id: ambulance-id, equipment-id: equipment-id })
)

(define-read-only (get-central-inventory (equipment-id uint))
  (map-get? central-inventory { equipment-id: equipment-id })
)

(define-read-only (check-stock-levels (ambulance-id uint) (equipment-id uint))
  (match (map-get? ambulance-inventory { ambulance-id: ambulance-id, equipment-id: equipment-id })
    inventory (match (map-get? equipment-types { equipment-id: equipment-id })
      equipment (ok {
        current-stock: (get current-stock inventory),
        min-required: (get min-stock-level equipment),
        needs-restock: (< (get current-stock inventory) (get min-stock-level equipment)),
        is-expired: (< (get expiration-date inventory) block-height)
      })
      ERR-EQUIPMENT-NOT-FOUND
    )
    ERR-EQUIPMENT-NOT-FOUND
  )
)

(define-read-only (get-maintenance-schedule (ambulance-id uint) (equipment-id uint))
  (map-get? maintenance-schedules { ambulance-id: ambulance-id, equipment-id: equipment-id })
)

(define-read-only (check-maintenance-due (ambulance-id uint) (equipment-id uint))
  (match (map-get? maintenance-schedules { ambulance-id: ambulance-id, equipment-id: equipment-id })
    schedule (ok (<= (get next-maintenance schedule) block-height))
    (ok false)
  )
)

;; Initialize contract
(map-set authorized-inventory-managers CONTRACT-OWNER true)
