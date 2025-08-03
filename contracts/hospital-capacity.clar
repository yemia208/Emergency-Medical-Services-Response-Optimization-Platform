;; Hospital Emergency Room Capacity Tracking Contract
;; Directs ambulances to hospitals with available beds

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-HOSPITAL-NOT-FOUND (err u201))
(define-constant ERR-INVALID-CAPACITY (err u202))
(define-constant ERR-INSUFFICIENT-CAPACITY (err u203))
(define-constant ERR-INVALID-COORDINATES (err u204))

;; Data Variables
(define-data-var next-hospital-id uint u1)

;; Data Maps
(define-map hospitals
  { hospital-id: uint }
  {
    name: (string-ascii 50),
    latitude: int,
    longitude: int,
    total-beds: uint,
    available-beds: uint,
    trauma-level: uint,
    specialties: (list 10 (string-ascii 30)),
    last-updated: uint
  }
)

(define-map bed-reservations
  { hospital-id: uint, reservation-id: uint }
  {
    ambulance-id: uint,
    patient-priority: uint,
    estimated-arrival: uint,
    status: (string-ascii 20),
    created-at: uint
  }
)

(define-map authorized-hospitals principal bool)
(define-map hospital-admins principal uint)

;; Authorization Functions
(define-public (add-hospital-admin (admin principal) (hospital-id uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-some (map-get? hospitals { hospital-id: hospital-id })) ERR-HOSPITAL-NOT-FOUND)
    (ok (map-set hospital-admins admin hospital-id))
  )
)

(define-private (is-hospital-admin (admin principal))
  (is-some (map-get? hospital-admins admin))
)

(define-private (get-admin-hospital (admin principal))
  (map-get? hospital-admins admin)
)

;; Hospital Management Functions
(define-public (register-hospital
  (name (string-ascii 50))
  (latitude int)
  (longitude int)
  (total-beds uint)
  (trauma-level uint)
  (specialties (list 10 (string-ascii 30)))
)
  (let ((hospital-id (var-get next-hospital-id)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= latitude -90000000) (<= latitude 90000000)) ERR-INVALID-COORDINATES)
    (asserts! (and (>= longitude -180000000) (<= longitude 180000000)) ERR-INVALID-COORDINATES)
    (asserts! (> total-beds u0) ERR-INVALID-CAPACITY)
    (asserts! (and (>= trauma-level u1) (<= trauma-level u4)) ERR-INVALID-CAPACITY)
    (map-set hospitals
      { hospital-id: hospital-id }
      {
        name: name,
        latitude: latitude,
        longitude: longitude,
        total-beds: total-beds,
        available-beds: total-beds,
        trauma-level: trauma-level,
        specialties: specialties,
        last-updated: block-height
      }
    )
    (var-set next-hospital-id (+ hospital-id u1))
    (ok hospital-id)
  )
)

(define-public (update-bed-capacity (hospital-id uint) (available-beds uint))
  (let (
    (hospital (unwrap! (map-get? hospitals { hospital-id: hospital-id }) ERR-HOSPITAL-NOT-FOUND))
    (admin-hospital (unwrap! (get-admin-hospital tx-sender) ERR-NOT-AUTHORIZED))
  )
    (asserts! (is-eq admin-hospital hospital-id) ERR-NOT-AUTHORIZED)
    (asserts! (<= available-beds (get total-beds hospital)) ERR-INVALID-CAPACITY)
    (map-set hospitals
      { hospital-id: hospital-id }
      (merge hospital {
        available-beds: available-beds,
        last-updated: block-height
      })
    )
    (ok true)
  )
)

(define-public (reserve-bed (hospital-id uint) (ambulance-id uint) (patient-priority uint) (estimated-arrival uint))
  (let (
    (hospital (unwrap! (map-get? hospitals { hospital-id: hospital-id }) ERR-HOSPITAL-NOT-FOUND))
    (reservation-id block-height)
  )
    (asserts! (> (get available-beds hospital) u0) ERR-INSUFFICIENT-CAPACITY)
    (asserts! (and (>= patient-priority u1) (<= patient-priority u5)) ERR-INVALID-CAPACITY)
    (map-set bed-reservations
      { hospital-id: hospital-id, reservation-id: reservation-id }
      {
        ambulance-id: ambulance-id,
        patient-priority: patient-priority,
        estimated-arrival: estimated-arrival,
        status: "reserved",
        created-at: block-height
      }
    )
    (map-set hospitals
      { hospital-id: hospital-id }
      (merge hospital {
        available-beds: (- (get available-beds hospital) u1),
        last-updated: block-height
      })
    )
    (ok reservation-id)
  )
)

(define-public (confirm-admission (hospital-id uint) (reservation-id uint))
  (let (
    (reservation (unwrap! (map-get? bed-reservations { hospital-id: hospital-id, reservation-id: reservation-id }) ERR-HOSPITAL-NOT-FOUND))
    (admin-hospital (unwrap! (get-admin-hospital tx-sender) ERR-NOT-AUTHORIZED))
  )
    (asserts! (is-eq admin-hospital hospital-id) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status reservation) "reserved") ERR-INVALID-CAPACITY)
    (map-set bed-reservations
      { hospital-id: hospital-id, reservation-id: reservation-id }
      (merge reservation {
        status: "admitted"
      })
    )
    (ok true)
  )
)

(define-public (release-bed (hospital-id uint) (reservation-id uint))
  (let (
    (hospital (unwrap! (map-get? hospitals { hospital-id: hospital-id }) ERR-HOSPITAL-NOT-FOUND))
    (reservation (unwrap! (map-get? bed-reservations { hospital-id: hospital-id, reservation-id: reservation-id }) ERR-HOSPITAL-NOT-FOUND))
    (admin-hospital (unwrap! (get-admin-hospital tx-sender) ERR-NOT-AUTHORIZED))
  )
    (asserts! (is-eq admin-hospital hospital-id) ERR-NOT-AUTHORIZED)
    (map-set bed-reservations
      { hospital-id: hospital-id, reservation-id: reservation-id }
      (merge reservation {
        status: "discharged"
      })
    )
    (map-set hospitals
      { hospital-id: hospital-id }
      (merge hospital {
        available-beds: (+ (get available-beds hospital) u1),
        last-updated: block-height
      })
    )
    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-hospital (hospital-id uint))
  (map-get? hospitals { hospital-id: hospital-id })
)

(define-read-only (get-hospital-capacity (hospital-id uint))
  (match (map-get? hospitals { hospital-id: hospital-id })
    hospital (ok {
      total-beds: (get total-beds hospital),
      available-beds: (get available-beds hospital),
      occupancy-rate: (/ (* (- (get total-beds hospital) (get available-beds hospital)) u100) (get total-beds hospital))
    })
    ERR-HOSPITAL-NOT-FOUND
  )
)

(define-read-only (find-available-hospitals (min-beds uint) (trauma-level uint))
  (var-get next-hospital-id)
)

(define-read-only (get-reservation (hospital-id uint) (reservation-id uint))
  (map-get? bed-reservations { hospital-id: hospital-id, reservation-id: reservation-id })
)

(define-read-only (calculate-hospital-distance (hospital-id uint) (latitude int) (longitude int))
  (match (map-get? hospitals { hospital-id: hospital-id })
    hospital (let (
      (lat-diff (if (> (get latitude hospital) latitude)
                   (- (get latitude hospital) latitude)
                   (- latitude (get latitude hospital))))
      (lon-diff (if (> (get longitude hospital) longitude)
                   (- (get longitude hospital) longitude)
                   (- longitude (get longitude hospital))))
    )
      (ok (+ lat-diff lon-diff))
    )
    ERR-HOSPITAL-NOT-FOUND
  )
)

;; Initialize contract
(map-set authorized-hospitals CONTRACT-OWNER true)
