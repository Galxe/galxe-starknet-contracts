use array::ArrayTrait;
use starknet::ContractAddress;


#[starknet::interface]
trait IStarNFT<TContractState> {
    fn get_name(self: @TContractState) -> felt252;
    fn get_symbol(self: @TContractState) -> felt252;
    fn token_uri(self: @TContractState, token_id: u256) -> Array<felt252>;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn is_approved_for_all(
        self: @TContractState, owner: ContractAddress, operator: ContractAddress
    ) -> bool;

    fn owner_of(self: @TContractState, token_id: u256) -> ContractAddress;
    fn get_approved(self: @TContractState, token_id: u256) -> ContractAddress;

    fn set_approval_for_all(
        ref self: TContractState, operator: ContractAddress, approved: bool
    );
    fn approve(ref self: TContractState, to: ContractAddress, token_id: u256);
    fn transfer_from(
        ref self: TContractState, from: ContractAddress, to: ContractAddress, token_id: u256
    );
    fn has_minted(self: @TContractState, verify_id: u256) -> bool;
    fn campaign_claimed(self: @TContractState, cid: u256) -> u256;
    fn claim(
        ref self: TContractState, 
        cid: u256, 
        verify_id: u256, 
        cap: u256, 
        user: ContractAddress,
        signature: Array<felt252>
    );
    fn total_supply(self: @TContractState) -> u256;
}

#[starknet::interface]
trait ISignerTrait<TContractState> {
    fn set_signer_public_key(ref self: TContractState, new_signer_public_key: felt252);
    fn get_signer_public_key(self: @TContractState) -> felt252;
    fn is_valid_signature(self: @TContractState, hash: felt252, signature: Array<felt252>) -> bool;
    fn hash_message(self: @TContractState, cid: u256, verify_id: u256, cap: u256, user: ContractAddress) -> felt252;
}

#[starknet::interface]
trait IOwnable<TContractState> {
    fn owner(self: @TContractState) -> ContractAddress;
    fn transfer_ownership(ref self: TContractState, new_owner: ContractAddress);
}

#[starknet::contract]
mod StarNFT {
    use array::ArrayTrait;
    use array::SpanTrait;
    use option::OptionTrait;

    use starknet::get_caller_address;
    use starknet::contract_address_const;
    use starknet::get_contract_address;
    use starknet::ContractAddress;
    use starknet::get_tx_info;
    use starknet::contract_address_to_felt252;

    use ecdsa::check_ecdsa_signature;
    use poseidon::poseidon_hash_span;
    use traits::Into;
    use traits::TryInto;
    use zeroable::Zeroable;
    use box::BoxTrait;

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        base_uri: felt252,
        next_token_id: u256,
        owners: LegacyMap::<u256, ContractAddress>,
        balances: LegacyMap::<ContractAddress, u256>,
        token_approvals: LegacyMap::<u256, ContractAddress>,
        operator_approvals: LegacyMap::<(ContractAddress, ContractAddress), bool>,
        // save all used verify_id
        used_verify_id: LegacyMap::<u256, bool>,
        // all campaign claimed count
        campaign_claimed: LegacyMap::<u256, u256>,
        // signer
        signer_public_key: felt252,
        // ownable
        owner: ContractAddress,
    }

    /// ERC721
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Approval: Approval,
        Transfer: Transfer,
        ApprovalForAll: ApprovalForAll,
        Claim: Claim,
        OwnershipTransferred: OwnershipTransferred,
        UpdateSigner: UpdateSigner
    }
    #[derive(Drop, starknet::Event)]
    struct Approval {
        owner: ContractAddress, 
        to: ContractAddress, 
        token_id: u256
    }
    #[derive(Drop, starknet::Event)]
    struct Transfer {
        from: ContractAddress, 
        to: ContractAddress, 
        token_id: u256
    }
    #[derive(Drop, starknet::Event)]
    struct ApprovalForAll {
        owner: ContractAddress, 
        operator: ContractAddress, 
        approved: bool
    }
    /// StarNFT
    #[derive(Drop, starknet::Event)]
    struct Claim {
        campaign_id: u256,
        verify_id: u256,
        minter: ContractAddress,
        owner: ContractAddress,
        nft_id: u256
    }
    #[derive(Drop, starknet::Event)]
    struct UpdateSigner {
        previous_signer_public_key: felt252,
        new_signer_public_key: felt252
    }
    /// Ownable
    #[derive(Drop, starknet::Event)]
    struct OwnershipTransferred {
        previous_owner: ContractAddress,
        new_owner: ContractAddress,
    }
    
    #[constructor]
    fn constructor(
        ref self: ContractState, 
        _name: felt252, 
        _symbol: felt252, 
        _base_uri: felt252,
        _signer_public_key: felt252,
        _owner: ContractAddress,
    ) {
        self.init(_name, _symbol, _base_uri, _signer_public_key, _owner);
    }

    #[external(v0)]
    impl OwnableImpl of super::IOwnable<ContractState> {
        fn owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            assert(!new_owner.is_zero(), 'New owner is the zero address');
            self.assert_only_owner();
            self._transfer_ownership(new_owner);
        }
    }

    #[external(v0)]
    impl SignerImpl of super::ISignerTrait<ContractState> {
        fn set_signer_public_key(ref self: ContractState, new_signer_public_key: felt252) {
            self.assert_only_owner();
            let previous_signer_public_key = self.signer_public_key.read();
            self.signer_public_key.write(new_signer_public_key);

            self
                .emit(
                    UpdateSigner { 
                        previous_signer_public_key: previous_signer_public_key,
                        new_signer_public_key: new_signer_public_key
                     }
                );
        }

        fn get_signer_public_key(self: @ContractState) -> felt252 {
            self.signer_public_key.read()
        }

        /// @dev
        /// hash: message hash
        /// signature: [r, s]
        fn is_valid_signature(
            self: @ContractState, hash: felt252, signature: Array<felt252>
        ) -> bool {
            self._is_valid_signature(hash, signature)
        }

        fn hash_message(self: @ContractState, cid: u256, verify_id: u256, cap: u256, user: ContractAddress) -> felt252 {
            self._hash_message(cid, verify_id, cap, user)
        }
    }

    #[external(v0)]
    impl StarNFTImpl of super::IStarNFT<ContractState> {
        fn get_name(self: @ContractState) -> felt252 {
            self.name.read()
        }

        fn get_symbol(self: @ContractState) -> felt252 {
            self.symbol.read()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            assert(!account.is_zero(), 'ERC721: address zero');
            self.balances.read(account)
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.next_token_id.read() - 1
        }

        fn is_approved_for_all(self: @ContractState, owner: ContractAddress, operator: ContractAddress) -> bool {
            self._is_approved_for_all(owner, operator)
        }

        fn token_uri(self: @ContractState, token_id: u256) -> Array<felt252> {
            self._require_minted(token_id);
            let base_uri = self._base_uri();
            let id = self._id_to_str(token_id);
            let mut input = ArrayTrait::new(); // felt252 array
            input.append(0x68747470733a2f2f677261706869676f2e);                 // https://graphigo.
            input.append(base_uri);                                             // prd or stg
            input.append(0x2e67616c6178792e65636f2f6d657461646174612f);         // .galaxy.eco/metadata/
            input.append(contract_address_to_felt252(get_contract_address()));  // contract
            input.append(0x2f);                                                 // /
            input.append(id);                                                   // id
            input.append(0x2e6a736f6e);                                         // .json
            input
        }

        fn owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            let owner = self._owner_of(token_id);
            assert(!owner.is_zero(), 'ERC721: invalid token ID');
            owner
        }

        fn get_approved(self: @ContractState, token_id: u256) -> ContractAddress {
            self._get_approved(token_id)
        }

        fn transfer_from(ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256) {
            assert(self._is_approved_or_owner(get_caller_address(), token_id), 'Caller is not owner or appvored');
            self._transfer(from, to, token_id);
        }

        fn set_approval_for_all(ref self: ContractState, operator: ContractAddress, approved: bool) {
            self._set_approval_for_all(get_caller_address(), operator, approved);
        }

        fn approve(ref self: ContractState, to: ContractAddress, token_id: u256) {
            let owner = self._owner_of(token_id);
            // Unlike Solidity, require is not supported, only assert can be used
            // The max length of error msg is 31 or there's an error
            assert(to != owner, 'Approval to current owner');
            // || is not supported currently so we use | here
            assert((get_caller_address() == owner) | self._is_approved_for_all(owner, get_caller_address()), 'Not token owner');
            self._approve(to, token_id);
        }

        fn has_minted(self: @ContractState, verify_id: u256) -> bool {
            self._has_minted(verify_id)
        }

        fn campaign_claimed(self: @ContractState, cid: u256) -> u256 {
            self.campaign_claimed.read(cid)
        }

        fn claim(
            ref self: ContractState, 
            cid: u256, 
            verify_id: u256, 
            cap: u256, 
            user: ContractAddress,
            signature: Array<felt252>
        ) {
            assert(!user.is_zero(), 'User is the zero address');
            assert(!self._has_minted(verify_id), 'Already minted');
            assert(self._is_valid_signature(self._hash_message(cid, verify_id, cap, user), signature), 'Invalid signature');
            assert(!self._is_exceeded_limit(cid, cap), 'Exceeded campaign limit');

            self._increase_campaign_minted(cid);
            self._set_minted(verify_id);
            let token_id = self._next_token_id();
            self._mint(user, token_id);

            self
                .emit(
                    Claim { 
                        campaign_id: cid,
                        verify_id: verify_id,
                        minter: get_caller_address(),
                        owner: user,
                        nft_id: token_id
                     }
                );
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _id_to_str(self: @ContractState, id: u256) -> felt252 {
            let mut id = id;
            let mut rst = 0;
            let mut idx = 0;
            loop {
                if id == 0 {
                    break;
                }

                rst = rst + (id % 10 + 48) * self._uint_shift(idx);
                idx = idx + 8;
                id = id / 10;
            };
            rst.try_into().unwrap()
        }

        fn _uint_shift(self: @ContractState, shift: u256) -> u256 {
            if shift == 8 {         // 1 bytes
                0x100
            } else if shift == 16 { // 2 bytes
                0x10000
            } else if shift == 32 { // 3 bytes
                0x1000000
            } else if shift == 40 { // 4 bytes
                0x100000000
            } else if shift == 48 { // 5 bytes
                0x10000000000
            } else if shift == 56 { // 6 bytes
                0x1000000000000
            } else if shift == 64 { // 7 bytes
                0x100000000000000
            } else {
                1
            }
        }
    }

    #[generate_trait]
    impl StorageImpl of StorageTrait {
        fn init(
            ref self: ContractState,
            _name: felt252, 
            _symbol: felt252, 
            _base_uri: felt252,
            _signer_public_key: felt252,    
            _owner: ContractAddress,
        ) {
            self.name.write(_name);
            self.symbol.write(_symbol);
            self.base_uri.write(_base_uri);
            self.next_token_id.write(1);

            // set owner
            self._transfer_ownership(_owner);
            // set signer_public_key
            self.signer_public_key.write(_signer_public_key);
        }

        fn _set_minted(ref self: ContractState, verify_id: u256) {
            self.used_verify_id.write(verify_id, true);
        }

        fn _has_minted(self: @ContractState, verify_id: u256) -> bool {
            self.used_verify_id.read(verify_id)
        }

        fn _increase_campaign_minted(ref self: ContractState, cid: u256) {
            let minted = self.campaign_claimed.read(cid);
            self.campaign_claimed.write(cid, minted+1);
        }

        fn _is_exceeded_limit(self: @ContractState, cid: u256, cap: u256) -> bool {
            if cap == 0_u256 {
                false
            } else {
                self.campaign_claimed.read(cid) >= cap
            }        
        }

        fn assert_only_owner(self: @ContractState) {
            let owner: ContractAddress = self.owner.read();
            let caller: ContractAddress = get_caller_address();
            assert(!caller.is_zero(), 'Caller is the zero address');
            assert(caller == owner, 'Caller is not the owner');
        }

        fn _transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            let previous_owner: ContractAddress = self.owner.read();
            self.owner.write(new_owner);
            self
                .emit(
                    OwnershipTransferred { previous_owner: previous_owner, new_owner: new_owner }
                );
        }

        fn _is_valid_signature(
            self: @ContractState, hash: felt252, signature: Array<felt252>
        ) -> bool {
            let signature = signature.span();
            let valid_length = signature.len() == 2_u32;

            if valid_length {
                check_ecdsa_signature(
                    hash, self.signer_public_key.read(), *signature.at(0_u32), *signature.at(1_u32)
                )
            } else {
                false
            }
        }

        fn _hash_message(self: @ContractState, cid: u256, verify_id: u256, cap: u256, user: ContractAddress) -> felt252 {
            let chain_id = get_tx_info().unbox().chain_id; /// felt252
            let nft_core = contract_address_to_felt252(get_contract_address());  /// ContractAddress
            let mut input = ArrayTrait::new(); // felt252 array
            input.append(chain_id);
            input.append(nft_core.into());
            input.append(cid.try_into().unwrap());
            input.append(verify_id.try_into().unwrap());
            input.append(cap.try_into().unwrap());
            input.append(contract_address_to_felt252(user));
            poseidon_hash_span(input.span())
        }

        fn _set_approval_for_all(ref self: ContractState, owner: ContractAddress, operator: ContractAddress, approved: bool) {
            assert(owner != operator, 'ERC721: approve to caller');
            self.operator_approvals.write((owner, operator), approved);
            self.emit(Event::ApprovalForAll(ApprovalForAll { owner, operator, approved }));
        }

        fn _approve(ref self: ContractState, to: ContractAddress, token_id: u256) {
            self.token_approvals.write(token_id, to);
            self.emit(Event::Approval(Approval {owner: self._owner_of(token_id), to, token_id }));
        }

        fn _is_approved_for_all(self: @ContractState, owner: ContractAddress, operator: ContractAddress) -> bool {
            self.operator_approvals.read((owner, operator))
        }

        fn _owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            self.owners.read(token_id)
        }

        fn _next_token_id(ref self: ContractState) -> u256 {
            let id = self.next_token_id.read();
            self.next_token_id.write(id + 1);
            id
        }

        fn _exists(self: @ContractState, token_id: u256) -> bool {
            !self._owner_of(token_id).is_zero()
        }

        fn _base_uri(self: @ContractState) -> felt252 {
            self.base_uri.read()
        }

        fn _get_approved(self: @ContractState, token_id: u256) -> ContractAddress {
            self._require_minted(token_id);
            self.token_approvals.read(token_id)
        }

        fn _require_minted(self: @ContractState, token_id: u256) {
            assert(self._exists(token_id), 'ERC721: invalid token ID');
        }

        fn _is_approved_or_owner(self: @ContractState, spender: ContractAddress, token_id: u256) -> bool {
            let owner = self.owners.read(token_id);
            // || is not supported currently so we use | here
            (spender == owner)
                | self._is_approved_for_all(owner, spender) 
                | (self._get_approved(token_id) == spender)
        }

        fn _transfer(ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256) {
            assert(from == self._owner_of(token_id), 'Transfer from incorrect owner');
            assert(!to.is_zero(), 'ERC721: transfer to 0');

            self._beforeTokenTransfer(from, to, token_id, 1.into());
            assert(from == self._owner_of(token_id), 'Transfer from incorrect owner');

            self.token_approvals.write(token_id, contract_address_const::<0>());

            self.balances.write(from, self.balances.read(from) - 1.into());
            self.balances.write(to, self.balances.read(to) + 1.into());

            self.owners.write(token_id, to);

            self.emit(Event::Transfer(Transfer { from, to, token_id }));

            self._afterTokenTransfer(from, to, token_id, 1.into());
        }

        fn _mint(ref self: ContractState, to: ContractAddress, token_id: u256) {
            assert(!to.is_zero(), 'ERC721: mint to 0');
            assert(!self._exists(token_id), 'ERC721: already minted');
            self._beforeTokenTransfer(contract_address_const::<0>(), to, token_id, 1.into());
            assert(!self._exists(token_id), 'ERC721: already minted');

            self.balances.write(to, self.balances.read(to) + 1.into());
            self.owners.write(token_id, to);
            // contract_address_const::<0>() => means 0 address
            self.emit(Event::Transfer(Transfer {
                from: contract_address_const::<0>(), 
                to,
                token_id
            }));

            self._afterTokenTransfer(contract_address_const::<0>(), to, token_id, 1.into());
        }

    
        fn _burn(ref self: ContractState, token_id: u256) {
            let owner = self._owner_of(token_id);
            self._beforeTokenTransfer(owner, contract_address_const::<0>(), token_id, 1.into());
            let owner = self._owner_of(token_id);
            self.token_approvals.write(token_id, contract_address_const::<0>());

            self.balances.write(owner, self.balances.read(owner) - 1.into());
            self.owners.write(token_id, contract_address_const::<0>());
            self.emit(Event::Transfer(Transfer {
                from: owner,
                to: contract_address_const::<0>(),
                token_id
            }));

            self._afterTokenTransfer(owner, contract_address_const::<0>(), token_id, 1.into());
        }

        fn _beforeTokenTransfer(
            ref self: ContractState, 
            from: ContractAddress, 
            to: ContractAddress, 
            first_token_id: u256, 
            batch_size: u256
        ) {}

        fn _afterTokenTransfer(
            ref self: ContractState, 
            from: ContractAddress, 
            to: ContractAddress, 
            first_token_id: u256, 
            batch_size: u256
        ) {}

    }
}