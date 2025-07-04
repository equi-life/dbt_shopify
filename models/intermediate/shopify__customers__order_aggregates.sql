with orders as (

    select *
    from {{ var('shopify_order') }}
    where customer_id is not null
    and cancel_reason is null --BF Mod: Dont want canceled orders to count in customer totals    

), order_aggregates as (

    select *
    from {{ ref('shopify__orders__order_line_aggregates') }}

), transactions as (

    select *
    from {{ ref('shopify__transactions')}}

    where lower(status) = 'success'
    and lower(kind) not in ('authorization', 'void')
    and lower(gateway) != 'gift_card' -- redeeming a giftcard does not introduce new revenue

), transaction_aggregates as (
    -- this is necessary as customers can pay via multiple payment gateways
    select 
        order_id,
        source_relation,
        lower(kind) as kind,
        sum(currency_exchange_calculated_amount) as currency_exchange_calculated_amount

    from transactions
    {{ dbt_utils.group_by(n=3) }}

), aggregated as (

    select
        orders.customer_id,
        orders.source_relation,
        min(orders.created_timestamp) as first_order_timestamp,
        max(orders.created_timestamp) as most_recent_order_timestamp,
        --avg(transaction_aggregates.currency_exchange_calculated_amount) as avg_order_value,
        avg(orders.subtotal_price) as avg_order_value,
        --sum(transaction_aggregates.currency_exchange_calculated_amount) as lifetime_total_spent,
        sum(orders.subtotal_price) as lifetime_total_spent,
        sum(refunds.currency_exchange_calculated_amount) as lifetime_total_refunded,
        count(distinct orders.order_id) as lifetime_count_orders,
        avg(order_aggregates.order_total_quantity) as avg_quantity_per_order,
        sum(order_aggregates.order_total_tax) as lifetime_total_tax,
        avg(order_aggregates.order_total_tax) as avg_tax_per_order,
        sum(order_aggregates.order_total_discount) as lifetime_total_discount,
        avg(order_aggregates.order_total_discount) as avg_discount_per_order,
        sum(order_aggregates.order_total_shipping) as lifetime_total_shipping,
        avg(order_aggregates.order_total_shipping) as avg_shipping_per_order,
        sum(order_aggregates.order_total_shipping_with_discounts) as lifetime_total_shipping_with_discounts,
        avg(order_aggregates.order_total_shipping_with_discounts) as avg_shipping_with_discounts_per_order,
        sum(order_aggregates.order_total_shipping_tax) as lifetime_total_shipping_tax,
        avg(order_aggregates.order_total_shipping_tax) as avg_shipping_tax_per_order,
        --fields not in Package model
        min(orders.order_id) as first_order_id,
        max(orders.order_id) as most_recent_order_id

    from orders
    left join transaction_aggregates 
        on orders.order_id = transaction_aggregates.order_id
        and orders.source_relation = transaction_aggregates.source_relation
        and transaction_aggregates.kind in ('sale','capture')
    left join transaction_aggregates as refunds
        on orders.order_id = refunds.order_id
        and orders.source_relation = refunds.source_relation
        and refunds.kind = 'refund'
    left join order_aggregates
        on orders.order_id = order_aggregates.order_id
        and orders.source_relation = order_aggregates.source_relation
    
    {{ dbt_utils.group_by(n=2) }}
)

select *
from aggregated